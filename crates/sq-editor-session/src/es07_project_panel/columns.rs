//! Cell text, item kinds and icons, drop classification and the saved column layout of the Project panel (Swift
//! `ProjectPanelColumns`, plus the formatting helpers of `ProjectPanelModel`). Pure logic: the view draws.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use sq_core_color::ColorSpaceIdExt;
use sq_core_model::{BinItemRef, MediaKind, MediaRef};
use sq_core_time::{Id, Time};
use sq_library::library_folder_store::SettingsStore;

use super::{Column, ProjectPanelModel};

// MARK: - Formatting

impl ProjectPanelModel {
    /// "29.97 fps" (two decimals, trailing zeros trimmed).
    pub(super) fn fps_string(frame_duration: Time) -> String {
        if frame_duration.value() <= 0 {
            return String::new();
        }
        format!(
            "{} fps",
            trim_zeros(format!("{:.2}", frame_duration.timescale() as f64 / frame_duration.value() as f64))
        )
    }

    // Swift: ProjectPanelColumns.swift:18
    pub fn timecode(d: Time, frame_duration: Option<Time>) -> String {
        if d.is_negative() {
            return String::new();
        }
        let two = |n: i64| format!("{n:02}");
        if let Some(fd) = frame_duration.filter(|fd| fd.value() > 0) {
            let fps = ((fd.timescale() as f64 / fd.value() as f64).round() as i64).max(1);
            let frames = d.frame_index(fd);
            let s = frames / fps;
            return format!("{}:{}:{}:{}", two(s / 3600), two(s / 60 % 60), two(s % 60), two(frames % fps));
        }
        let s = d.value() / d.timescale();
        format!("{}:{}:{}", two(s / 3600), two(s / 60 % 60), two(s % 60))
    }

    // Swift: ProjectPanelModel.swift:894
    pub fn seconds(t: Time) -> f64 {
        t.value() as f64 / t.timescale() as f64
    }

    // Swift: ProjectPanelModel.swift:896
    pub fn codec_name(four_cc: &str) -> String {
        match four_cc {
            "avc1" | "avc3" => "H.264",
            "hvc1" | "hev1" => "HEVC",
            "dvh1" | "dvhe" => "HEVC (Dolby Vision)",
            "apch" => "ProRes 422 HQ",
            "apcn" => "ProRes 422",
            "apcs" => "ProRes 422 LT",
            "apco" => "ProRes 422 Proxy",
            "ap4h" => "ProRes 4444",
            "ap4x" => "ProRes 4444 XQ",
            "av01" => "AV1",
            "vp09" => "VP9",
            other => other.trim_matches(' '),
        }
        .to_string()
    }

    /// Item info for a variable-frame-rate clip (phone and screen recordings): its frames are not evenly spaced, so
    /// picture can drift against audio. `None` for constant-rate clips and files without picture.
    // Swift: ProjectPanelModel.swift:917
    pub fn variable_frame_rate_note(m: &MediaRef) -> Option<String> {
        let info = m.info.as_ref()?;
        (!info.is_still && info.video.as_ref()?.is_variable_frame_rate).then(|| {
            "Variable frame rate: picture can drift against audio. Conform the clip to a constant rate before editing."
                .to_string()
        })
    }

    /// "3840×2160 29.97 H.264 4:2:2 10-bit"; audio-only: "48 kHz 2 ch AAC"; "" without probe info.
    // Swift: ProjectPanelModel.swift:923
    pub fn format_string(m: &MediaRef) -> String {
        let info = m.info.as_ref();
        if let Some(v) = info.and_then(|i| i.video.as_ref()) {
            let fps = trim_zeros(format!(
                "{:.2}",
                v.nominal_frame_duration.timescale() as f64 / v.nominal_frame_duration.value() as f64
            ));
            if info.is_some_and(|i| i.is_still) {
                return format!("{}\u{D7}{} Still image", v.display_width(), v.display_height());
            }
            return format!(
                "{}\u{D7}{} {fps}{} {} {} {}-bit",
                v.display_width(),
                v.display_height(),
                if v.is_variable_frame_rate { " VFR" } else { "" },
                Self::codec_name(&v.codec),
                v.chroma,
                v.bit_depth
            );
        }
        if let Some(a) = info.and_then(|i| i.audio.as_ref()) {
            return format!("{} kHz {} ch {}", khz(a.sample_rate), a.channels, a.codec.trim_matches(' '));
        }
        String::new()
    }

    /// Short Format cell: the log profile when the file is log ("S-Log3"), else the picture size; audio-only files show
    /// the sample rate ("44.1 kHz"). `format_string` is the whole line.
    // Swift: ProjectPanelModel.swift:942
    pub fn format_label(m: &MediaRef) -> String {
        let info = m.info.as_ref();
        if let Some(v) = info.and_then(|i| i.video.as_ref()) {
            if let Some(cs) = info.and_then(|i| i.detected_color_space).filter(|cs| cs.is_log() || cs.is_hdr()) {
                return cs.display_name().split('/').next().unwrap_or("").trim_matches(' ').to_string();
            }
            return format!("{}\u{D7}{}", v.display_width(), v.display_height());
        }
        if let Some(a) = info.and_then(|i| i.audio.as_ref()) {
            return format!("{} kHz", khz(a.sample_rate));
        }
        String::new()
    }

    /// "9:16" for 1080×1920; "" for an empty size.
    // Swift: ProjectPanelModel.swift:958
    pub fn aspect_label(width: i64, height: i64) -> String {
        if width <= 0 || height <= 0 {
            return String::new();
        }
        let g = gcd(width, height);
        format!("{}:{}", width / g, height / g)
    }

    /// HH:MM:SS:FF (non-drop, frame rate rounded); audio-only HH:MM:SS; "" when unknown.
    // Swift: ProjectPanelModel.swift:966
    pub fn duration_string(m: &MediaRef) -> String {
        let Some(d) = m.duration.or(m.info.as_ref().map(|i| i.duration)).filter(|d| !d.is_negative()) else {
            return String::new();
        };
        Self::timecode(d, m.info.as_ref().and_then(|i| i.video.as_ref()).map(|v| v.nominal_frame_duration))
    }
}

/// The info card under the list (redesign Project panel): "C2171.MP4 · 3840 × 2160 · 25 fps · S-Log3 · 11 uses". Empty
/// parts are left out.
/// `fps` is the frame rate cell with its unit ("25 fps"), which the cell already carries.
pub(super) fn info_line_text(name: &str, resolution: &str, fps: &str, color: &str, uses: usize) -> String {
    let res = resolution.replace('\u{D7}', " \u{D7} ");
    let uses = format!("{uses} {}", if uses == 1 { "use" } else { "uses" });
    [name, res.as_str(), fps, color, uses.as_str()]
        .into_iter()
        .filter(|p| !p.is_empty())
        .collect::<Vec<_>>()
        .join(" \u{B7} ")
}

fn gcd(a: i64, b: i64) -> i64 {
    if b == 0 { a } else { gcd(b, a % b) }
}

/// "44.1", "48" (one decimal, a trailing ".0" dropped).
fn khz(sample_rate: i64) -> String {
    let s = format!("{:.1}", sample_rate as f64 / 1000.0);
    s.strip_suffix(".0").map_or(s.clone(), str::to_string)
}

fn trim_zeros(mut f: String) -> String {
    while f.ends_with('0') {
        f.pop();
    }
    if f.ends_with('.') {
        f.pop();
    }
    f
}

// MARK: - Cell text

impl ProjectPanelModel {
    /// The info card text of a selected clip; `None` for bins, sequences and nothing known.
    pub fn info_line(&self, item: BinItemRef) -> Option<String> {
        let BinItemRef::Media(id) = item else { return None };
        let m = self.project.media(id)?;
        let color = m
            .info
            .as_ref()
            .and_then(|i| i.detected_color_space)
            .filter(|cs| cs.is_log() || cs.is_hdr())
            .map(|cs| cs.display_name().split('/').next().unwrap_or("").trim_matches(' ').to_string())
            .unwrap_or_default();
        Some(info_line_text(
            &m.name,
            &self.media_cell(Column::Resolution, id),
            &self.media_cell(Column::FrameRate, id),
            &color,
            self.project.use_count(id),
        ))
    }

    /// Full text behind a short cell (the Format column's whole line), `None` when the cell says it all.
    // Swift: ProjectPanelColumns.swift:33
    pub fn cell_tooltip(&self, column: Column, item: BinItemRef) -> Option<String> {
        let BinItemRef::Media(id) = item else { return None };
        let m = self.project.media(id)?;
        let note = Self::variable_frame_rate_note(m);
        match column {
            Column::FrameRate => note,
            Column::Format => {
                let full = Self::format_string(m);
                let text =
                    if full.is_empty() || full == self.cell_text(column, item) { None } else { Some(full.clone()) };
                match note {
                    None => text,
                    Some(n) => Some(
                        [text.unwrap_or(full), n].into_iter().filter(|s| !s.is_empty()).collect::<Vec<_>>().join("\n"),
                    ),
                }
            }
            _ => None,
        }
    }

    /// Text of `column` for a bin item: "" where the column does not apply.
    // Swift: ProjectPanelColumns.swift:48
    pub fn cell_text(&self, column: Column, item: BinItemRef) -> String {
        match (column, item) {
            (Column::Name, _) => self.display_name(item),
            (Column::Label, BinItemRef::Bin(_)) => String::new(),
            (Column::Label, _) => self.project.label_of(item).display_name().to_string(),
            (_, BinItemRef::Bin(_)) => String::new(),
            (_, BinItemRef::Media(id)) => self.media_cell(column, id),
            (_, BinItemRef::Sequence(id)) => {
                let Some(t) = self.project.timelines.iter().find(|t| t.id == id) else { return String::new() };
                match column {
                    Column::FrameRate => Self::fps_string(t.frame_duration()),
                    Column::Duration => Self::timecode(t.duration(), Some(t.frame_duration())),
                    Column::Format => Self::aspect_label(t.format.width, t.format.height),
                    Column::Resolution => format!("{}\u{D7}{}", t.format.width, t.format.height),
                    Column::Audio => format!("{} kHz", khz(t.format.audio_sample_rate)),
                    _ => String::new(),
                }
            }
        }
    }

    fn media_cell(&self, column: Column, id: Id) -> String {
        let Some(m) = self.project.media(id) else { return String::new() };
        let info = m.info.as_ref();
        match column {
            Column::FrameRate => match info.and_then(|i| i.video.as_ref()) {
                Some(v) => {
                    Self::fps_string(v.nominal_frame_duration) + if v.is_variable_frame_rate { " VFR" } else { "" }
                }
                None => String::new(),
            },
            Column::Duration => Self::duration_string(m),
            Column::Resolution => {
                info.and_then(|i| i.video.as_ref()).map_or(String::new(), |v| format!("{}\u{D7}{}", v.width, v.height))
            }
            Column::Codec => match info.and_then(|i| i.video.as_ref()) {
                Some(v) => Self::codec_name(&v.codec),
                None => {
                    info.and_then(|i| i.audio.as_ref()).map_or(String::new(), |a| a.codec.trim_matches(' ').to_string())
                }
            },
            Column::Audio => info
                .and_then(|i| i.audio.as_ref())
                .map_or(String::new(), |a| format!("{} kHz {} ch", khz(a.sample_rate), a.channels)),
            Column::InPoint => match self.project.source_marks.get(&id).and_then(|s| s.mark_in) {
                Some(t) => Self::timecode(t, info.and_then(|i| i.video.as_ref()).map(|v| v.nominal_frame_duration)),
                None => String::new(),
            },
            Column::FilePath => m.path.clone(),
            Column::Format => Self::format_label(m),
            Column::SourceTimecode => {
                if info.is_some_and(|i| i.is_still) {
                    return String::new();
                }
                match self.source_timecodes.get(&m.id) {
                    None => {
                        self.request_source_timecode(m);
                        String::new()
                    }
                    Some(known) => known
                        .as_ref()
                        .and_then(|tc| tc.label(info.and_then(|i| i.video.as_ref()).map(|v| v.nominal_frame_duration)))
                        .unwrap_or_default(),
                }
            }
            Column::Name | Column::Label => String::new(),
        }
    }

    /// Asks for the one background read of `m`'s source timecode (header only); the app reads the file off the UI thread
    /// (`take_source_timecode_requests`) and answers with `set_source_timecode`.
    // Swift: ProjectPanelModel.swift:191
    pub(super) fn request_source_timecode(&self, m: &MediaRef) {
        if self.source_timecodes.contains_key(&m.id) || !self.timecode_started.borrow_mut().insert(m.id) {
            return;
        }
        self.timecode_requests.borrow_mut().push((m.id, PathBuf::from(&m.path)));
    }

    /// Files whose source timecode has to be read now (each is handed out once).
    pub fn take_source_timecode_requests(&self) -> Vec<(Id, PathBuf)> {
        std::mem::take(&mut *self.timecode_requests.borrow_mut())
    }

    /// The read result of a source timecode request (`None` = the file has none); the panel reloads.
    pub fn set_source_timecode(&mut self, id: Id, timecode: Option<sq_media::source_timecode::SourceTimecode>) {
        self.source_timecodes.insert(id, timecode);
        self.version += 1;
    }
}

// MARK: - Item kinds and icons

/// What a bin item is, for its icon.
// Swift: ProjectPanelColumns.swift:92
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ProjectItemKind {
    Bin,
    Video,
    Audio,
    VideoAudio,
    Image,
    Sequence,
    NestedSequence,
    Text,
    Generator,
}

/// Icon composition of a Project panel icon (icon case names): `symbol`, plus an optional small `badge` drawn bottom-right.
// Swift: ProjectPanelColumns.swift:105
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct ProjectItemIcon {
    // Swift: ProjectPanelColumns.swift:106
    pub symbol: &'static str,
    // Swift: ProjectPanelColumns.swift:107
    pub badge: Option<&'static str>,
}

impl ProjectItemIcon {
    // Swift: ProjectPanelColumns.swift:108
    pub fn icon(kind: ProjectItemKind, offline: bool) -> ProjectItemIcon {
        let (symbol, badge) = if offline {
            ("unknown", None)
        } else {
            match kind {
                ProjectItemKind::Bin => ("folder", None),
                ProjectItemKind::Video => ("film", None),
                ProjectItemKind::Audio => ("waveform", None),
                ProjectItemKind::VideoAudio => ("film", Some("volume")),
                ProjectItemKind::Image => ("image", None),
                ProjectItemKind::Sequence => ("sequence", None),
                ProjectItemKind::NestedSequence => ("stack", None),
                ProjectItemKind::Text => ("text", None),
                ProjectItemKind::Generator => ("generator", None),
            }
        };
        ProjectItemIcon { symbol, badge }
    }
}

impl ProjectPanelModel {
    // Swift: ProjectPanelColumns.swift:126
    pub fn item_kind(&self, item: BinItemRef) -> ProjectItemKind {
        match item {
            BinItemRef::Bin(_) => ProjectItemKind::Bin,
            BinItemRef::Sequence(id) => {
                if self.project.nested_sequence_ids().contains(&id) {
                    ProjectItemKind::NestedSequence
                } else {
                    ProjectItemKind::Sequence
                }
            }
            BinItemRef::Media(id) => match self.project.media(id).map(MediaRef::kind) {
                Some(MediaKind::Audio) => ProjectItemKind::Audio,
                Some(MediaKind::Image) => ProjectItemKind::Image,
                Some(MediaKind::VideoAudio) => ProjectItemKind::VideoAudio,
                _ => ProjectItemKind::Video,
            },
        }
    }

    // Swift: ProjectPanelColumns.swift:139
    pub fn icon_of(&self, item: BinItemRef) -> ProjectItemIcon {
        let offline = matches!(item, BinItemRef::Media(id) if self.is_offline(id));
        ProjectItemIcon::icon(self.item_kind(item), offline)
    }
}

// MARK: - Drops

/// What a drop onto the panel means. Internal item ids always win over file paths: dragging a media item out also writes
/// its file path, and that must never re-import it.
// Swift: ProjectPanelColumns.swift:148
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ProjectDrop {
    Move(Vec<BinItemRef>),
    ImportFiles(Vec<PathBuf>),
    None,
}

impl ProjectDrop {
    // Swift: ProjectPanelColumns.swift:155
    pub fn classify(items: &[BinItemRef], files: &[PathBuf], known_paths: &BTreeSet<String>) -> ProjectDrop {
        if !items.is_empty() {
            return ProjectDrop::Move(items.to_vec());
        }
        let fresh: Vec<PathBuf> =
            files.iter().filter(|f| !known_paths.contains(f.to_string_lossy().as_ref())).cloned().collect();
        if fresh.is_empty() { ProjectDrop::None } else { ProjectDrop::ImportFiles(fresh) }
    }
}

impl ProjectPanelModel {
    // Swift: ProjectPanelColumns.swift:164
    pub fn classify_drop(&self, items: &[BinItemRef], files: &[PathBuf]) -> ProjectDrop {
        let known: BTreeSet<String> = self.project.media.iter().map(|m| m.path.clone()).collect();
        ProjectDrop::classify(items, files, &known)
    }
}

// MARK: - Saved column layout

/// Visible columns (in order) and widths of the Project panel, saved per user.
// Swift: ProjectPanelColumns.swift:170
#[derive(Clone, Debug, PartialEq)]
pub struct ProjectColumnLayout {
    visible: Vec<Column>,
    widths: BTreeMap<String, f64>,
}

#[derive(Serialize, Deserialize)]
struct LayoutWire {
    #[serde(default)]
    visible: Vec<String>,
    #[serde(default)]
    widths: BTreeMap<String, f64>,
}

impl ProjectColumnLayout {
    /// Settings key of the saved layout.
    // Swift: ProjectPanelColumns.swift:177
    pub const DEFAULTS_KEY: &'static str = "ProjectPanel.columns.v3";

    // Swift: ProjectPanelColumns.swift:175
    pub fn defaults() -> ProjectColumnLayout {
        ProjectColumnLayout::new(vec![Column::Name, Column::Duration], BTreeMap::new())
    }

    // Swift: ProjectPanelColumns.swift:178
    pub fn new(visible: Vec<Column>, widths: BTreeMap<String, f64>) -> ProjectColumnLayout {
        let mut seen = BTreeSet::new();
        let mut v: Vec<Column> = visible.into_iter().filter(|c| *c != Column::Name && seen.insert(*c)).collect();
        v.insert(0, Column::Name);
        ProjectColumnLayout { visible: v, widths }
    }

    pub fn visible(&self) -> &[Column] {
        &self.visible
    }

    pub fn widths(&self) -> &BTreeMap<String, f64> {
        &self.widths
    }

    /// Reads a saved layout; unknown column names (from a newer version) are dropped instead of failing.
    // Swift: ProjectPanelColumns.swift:186
    pub fn from_json(data: &[u8]) -> Option<ProjectColumnLayout> {
        let w: LayoutWire = serde_json::from_slice(data).ok()?;
        Some(ProjectColumnLayout::new(w.visible.iter().filter_map(|r| Column::from_raw(r)).collect(), w.widths))
    }

    pub fn to_json(&self) -> Option<Vec<u8>> {
        let wire = LayoutWire {
            visible: self.visible.iter().map(|c| c.raw_value().to_string()).collect(),
            widths: self.widths.clone(),
        };
        serde_json::to_vec(&wire).ok()
    }

    // Swift: ProjectPanelColumns.swift:194
    pub fn is_visible(&self, c: Column) -> bool {
        self.visible.contains(&c)
    }

    /// Shows or hides a column (new ones go last). The name column cannot be hidden.
    // Swift: ProjectPanelColumns.swift:198
    pub fn toggle(&mut self, c: Column) {
        if c == Column::Name {
            return;
        }
        match self.visible.iter().position(|v| *v == c) {
            Some(i) => {
                self.visible.remove(i);
            }
            None => self.visible.push(c),
        }
    }

    // Swift: ProjectPanelColumns.swift:202
    pub fn move_column(&mut self, c: Column, to_index: usize) {
        if c == Column::Name {
            return;
        }
        let Some(from) = self.visible.iter().position(|v| *v == c) else { return };
        self.visible.remove(from);
        self.visible.insert(to_index.clamp(1, self.visible.len()), c);
    }

    // Swift: ProjectPanelColumns.swift:208
    pub fn set_width(&mut self, w: f64, c: Column) {
        self.widths.insert(c.raw_value().to_string(), w);
    }

    /// The width the user dragged a column to, `None` while it is still automatic.
    // Swift: ProjectPanelColumns.swift:212
    pub fn user_width(&self, c: Column) -> Option<f64> {
        self.widths.get(c.raw_value()).copied()
    }

    // Swift: ProjectPanelColumns.swift:213
    pub fn width(&self, c: Column) -> f64 {
        self.user_width(c).unwrap_or_else(|| c.default_width())
    }

    // Swift: ProjectPanelColumns.swift:215
    pub fn load(settings: &dyn SettingsStore) -> ProjectColumnLayout {
        settings.data(Self::DEFAULTS_KEY).and_then(|d| Self::from_json(&d)).unwrap_or_else(Self::defaults)
    }

    // Swift: ProjectPanelColumns.swift:221
    pub fn save(&self, settings: &mut dyn SettingsStore) {
        if let Some(data) = self.to_json() {
            settings.set_data(Self::DEFAULTS_KEY, data);
        }
    }
}

// MARK: - Automatic widths

/// Compact default widths: the name column fits its longest entry (clamped), the other columns wrap their widest text.
// Swift: ProjectPanelColumns.swift:229
pub enum ProjectColumnSizing {}

impl ProjectColumnSizing {
    /// Room for the sort arrow next to a header title.
    // Swift: ProjectPanelColumns.swift:233
    pub const HEADER_EXTRA: f64 = 12.0;
}

#[cfg(test)]
mod info_line_tests {
    use super::info_line_text;

    #[test]
    fn the_info_line_joins_the_known_parts_with_dots() {
        assert_eq!(
            info_line_text("C2171.MP4", "3840\u{D7}2160", "25 fps", "S-Log3", 11),
            "C2171.MP4 \u{B7} 3840 \u{D7} 2160 \u{B7} 25 fps \u{B7} S-Log3 \u{B7} 11 uses"
        );
        assert_eq!(info_line_text("a.m4a", "", "", "", 1), "a.m4a \u{B7} 1 use");
    }
}
