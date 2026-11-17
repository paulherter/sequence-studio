// Swift: AppPlatform.swift
//! The seams between the shared panel hosts (this crate) and the platform app around them: the binary and the
//! platform crates (`sq-platform-mac`, `sq-platform-win`) each implement them in a small backend. All of them run on
//! the UI thread (Swift `@MainActor`); the app owns the implementations and lends them to its hosts.

use sq_audiofx::channel_monitor::ChannelMonitor;
use sq_audiofx::monitor_gain::MonitorSetting;
use sq_core_model::MediaRef;
use sq_core_time::{Id, Vec2};
use sq_draw::RgbaImage;
use sq_draw::ui_cx::DrawCursor;
use sq_editor_session::{ProgramEngine, SplitAxis};
use sq_runtime::ModalAsk;
use sq_uikit::sqcolor_value::SQColorValue;
use std::path::PathBuf;

/// Namespace of the platform texts.
pub enum AppPlatform {}

impl AppPlatform {
    /// The Captions panel's note under Create Captions… while no transcriber runs on the shared UI.
    /// One text for both platforms: the Mac transcriber (SQTranscribe) is not wired to the shared UI yet.
    pub const TRANSCRIPTION_HINT: &'static str = "Transcription is not available on the shared UI yet";
}

/// File choosers the panel hosts need beyond the shell's [`crate::ShellFilePicker`] (modal, `None` when canceled).
pub trait PanelFileChooser {
    /// Captions > Import: an .srt / .vtt file.
    fn choose_subtitles(&mut self) -> Option<PathBuf>;
    /// Captions > Export SRT: where to write.
    fn choose_srt_location(&mut self, suggested_name: &str) -> Option<PathBuf>;
    /// Program monitor > Export Frame: where to write; `formats` are the pop-up entries (label, file extension; the
    /// first is the default). The extension of the chosen path says which format to write (Mac: the panel's accessory).
    fn choose_frame_location(&mut self, suggested_name: &str, formats: &[(&str, &str)]) -> Option<PathBuf>;
    /// Marker List > Export CSV (File > Export Markers as CSV…): where to write.
    fn choose_csv_location(&mut self, suggested_name: &str) -> Option<PathBuf>;
    /// Color: LUT files (.cube, .3dl); `multiple` for Add LUTs to Library… (the Mac `allowsMultipleSelection`).
    fn choose_luts(&mut self, multiple: bool) -> Vec<PathBuf>;
}

/// The LUT files the choosers offer.
pub enum LUTFileTypes {}

impl LUTFileTypes {
    /// File extensions without the dot.
    pub const EXTENSIONS: [&'static str; 2] = ["cube", "3dl"];
}

/// A CPU copy of the picture the Program monitor shows: NV12 planes (luma, then interleaved chroma) or RGBA rows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AppPicture {
    pub bytes: Vec<u8>,
    pub width: usize,
    pub height: usize,
    pub full_range: bool,
    pub rgba: bool,
}

/// What the meters, scopes and monitor hosts need of the platform's Program engine beyond `ProgramEngine`: its
/// picture and the speaker-only monitoring stages.
pub trait AppPictureSource {
    /// A frame was composited (the monitor shows a picture, not the empty card).
    fn has_picture(&self) -> bool;
    /// Changes whenever the shown picture changes (scopes and uploads skip unchanged frames).
    fn picture_generation(&self) -> i64;
    /// The shown picture on the CPU (scopes); `None` while none is readable yet.
    fn scope_picture(&self) -> Option<AppPicture>;
    /// Frames the playback skipped (the monitor's drop dot).
    fn skipped_frames(&self) -> i64;
    /// Listening volume / Dim: speakers only (meters and export unaffected).
    fn set_monitor_gain(&mut self, setting: MonitorSetting);
    /// Monitoring Solo / Mute per output channel: speakers only.
    fn set_channel_monitor(&mut self, state: ChannelMonitor);
}

/// One engine a shared monitor host drives (the Program engine, the Source engine, a pane of the slip / trim two-up):
/// its transport and timeline (`player`), its picture and Export Frame.
pub trait AppMonitorEngine: AppPictureSource {
    /// The transport and timeline the hosts drive (SourceMonitorCore, the two-up's seeks).
    fn player(&self) -> &dyn ProgramEngine;
    /// `player` for the transport calls (Swift's class reference is mutable through the getter).
    fn player_mut(&mut self) -> &mut dyn ProgramEngine;
    /// Per frame: advance the engine's clock and decodes (an engine without a window layer renders here).
    fn tick(&mut self);
    /// The project's media changed (Windows: the engine's path table; the Mac resolver is shared, nothing to do).
    fn set_media(&mut self, media: &[MediaRef]);
    /// Export Frame: the shown frame as a PNG where the user picks; outcome lines go to `status` (it may be called
    /// later, from a task on the UI thread).
    fn export_frame(
        &mut self,
        suggested_name: &str,
        files: Option<&mut dyn PanelFileChooser>,
        status: Box<dyn FnMut(String)>,
    );
}

/// What the monitor hosts ask of the platform beyond the Program engine.
pub trait AppMonitorBackend {
    /// The Source monitor's own engine (with sound).
    fn make_source_engine(&mut self) -> Box<dyn AppMonitorEngine>;
    /// A silent engine for one pane of the slip / trim two-up.
    fn make_still_engine(&mut self) -> Box<dyn AppMonitorEngine>;
}

/// The pointer shape the shared UI asks for; each platform maps it to its cursors. The panels' own requests come
/// through `UiCx::hover.cursor`.
pub type AppPointerShape = DrawCursor;

/// The portable pointer rules: what the window shows over the shared panels this frame.
pub enum AppPointer {}

/// The facts [`AppPointer::shape`] decides on (Swift `AppPointer.Facts`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct AppPointerFacts {
    /// The dock divider under the pointer (`None`: none).
    pub divider: Option<SplitAxis>,
    /// The Keystones bar's edge under the pointer (resize).
    pub keystone_edge: bool,
    /// The eyedropper samples.
    pub sampling: bool,
    /// A text editor without its own caret rect is open (the monitor's on-canvas text field).
    pub text_editing: bool,
    /// The pointer is over the Program picture with the Type tool (Create in Text mode).
    pub type_tool_over_picture: bool,
    /// The Hand tool over the timeline.
    pub hand_over_timeline: bool,
    /// The shape the panel under the pointer asked for (`UiCx::hover.cursor`: timeline tool cursors, resize edges).
    pub panel: Option<DrawCursor>,
}

impl AppPointer {
    /// The eyedropper wins, then dividers and edges (a drag starts there), then text, then the panel's request, then
    /// the tool's own shape.
    pub fn shape(f: &AppPointerFacts) -> AppPointerShape {
        if f.sampling {
            return DrawCursor::Crosshair;
        }
        if let Some(axis) = f.divider {
            return if axis == SplitAxis::Horizontal { DrawCursor::ResizeLeftRight } else { DrawCursor::ResizeUpDown };
        }
        if f.keystone_edge {
            return DrawCursor::ResizeLeftRight;
        }
        if f.text_editing || f.type_tool_over_picture {
            return DrawCursor::IBeam;
        }
        if let Some(p) = f.panel {
            return p;
        }
        if f.hand_over_timeline {
            return DrawCursor::OpenHand;
        }
        DrawCursor::Arrow
    }
}

/// The eyedropper's screen sample (color picker, text block rows, Color Key): Windows reads the desktop per event;
/// the Mac runs its own loupe window over every screen.
pub trait AppScreenSampler {
    /// The platform's own eyedropper (pointer, loupe and click outside the draw list): the ask is answered once
    /// (`None` = canceled). `None` here: the host samples per event with the calls below and draws the loupe itself.
    fn own_eyedropper(&mut self) -> Option<ModalAsk<Option<SQColorValue>>>;
    /// The screen color under the pointer (`None` when unreadable).
    fn color_under_pointer(&mut self) -> Option<SQColorValue>;
}

/// The Mask tool's Magic mode: a segmenter picks the object under a click and stores its matte.
pub trait AppMagicMasks {
    /// A Magic click at `p` (frame fraction) on the overlay's clip `target`: Option subtracts, Shift starts a new mask.
    fn click(&mut self, p: Vec2, target: Option<Id>, subtract: bool, new_mask: bool);
    /// Per frame while Magic is on, once when it goes off: the segmenter prepares the parked frame of `target`.
    fn refresh(&mut self, target: Option<Id>, magic_on: bool, is_playing: bool);
    /// Mask Tint: the stored mattes of `masks` (Magic masks of the Effect Controls clip) at source time `pts`
    /// (seconds), laid over each other as one coverage picture (white, alpha = the 30 % tints composited). `image`
    /// `None`: none is in yet; `waiting`: a read still runs, so the host keeps the last tint. A segmenter without
    /// stored mattes draws no tint.
    fn mask_tint(&mut self, _masks: &[Id], _pts: f64) -> MaskTintPicture {
        MaskTintPicture::default()
    }
    /// The pointer rests at `p` (frame fraction) on the overlay's clip with the Magic tool, or left the picture
    /// (`None`): the segmenter may prepare a hover highlight, which `mask_tint` then lays over the tint.
    fn hover(&mut self, _p: Option<Vec2>, _target: Option<Id>) {}
    /// A hover highlight is ready or pending for the shown frame: `mask_tint` is asked even without a stored mask.
    fn has_hover(&self) -> bool {
        false
    }
}

/// The coverage picture of a [`MaskTintPicture`] with a generation that moves when it changes (the Swift tuple
/// `(RGBAImage, generation: Int)`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MaskTintImage {
    pub image: RgbaImage,
    pub generation: i64,
}

/// One Mask Tint answer ([`AppMagicMasks::mask_tint`]).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct MaskTintPicture {
    pub image: Option<MaskTintImage>,
    pub waiting: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shape(f: AppPointerFacts) -> DrawCursor {
        AppPointer::shape(&f)
    }

    #[test]
    fn pointer_rules_keep_the_swift_order() {
        assert_eq!(shape(AppPointerFacts::default()), DrawCursor::Arrow);
        let all = AppPointerFacts {
            divider: Some(SplitAxis::Vertical),
            keystone_edge: true,
            sampling: true,
            text_editing: true,
            type_tool_over_picture: true,
            hand_over_timeline: true,
            panel: Some(DrawCursor::Razor),
        };
        assert_eq!(shape(all), DrawCursor::Crosshair);
        let no_sample = AppPointerFacts { sampling: false, ..all };
        assert_eq!(shape(no_sample), DrawCursor::ResizeUpDown);
        let horizontal = AppPointerFacts { divider: Some(SplitAxis::Horizontal), ..no_sample };
        assert_eq!(shape(horizontal), DrawCursor::ResizeLeftRight);
        let no_divider = AppPointerFacts { divider: None, keystone_edge: false, ..no_sample };
        assert_eq!(shape(no_divider), DrawCursor::IBeam);
        let no_text = AppPointerFacts { text_editing: false, type_tool_over_picture: false, ..no_divider };
        assert_eq!(shape(no_text), DrawCursor::Razor);
        assert_eq!(shape(AppPointerFacts { panel: None, ..no_text }), DrawCursor::OpenHand);
        assert_eq!(
            shape(AppPointerFacts { keystone_edge: true, ..AppPointerFacts::default() }),
            DrawCursor::ResizeLeftRight
        );
    }

    struct NoSegmenter;
    impl AppMagicMasks for NoSegmenter {
        fn click(&mut self, _p: Vec2, _target: Option<Id>, _subtract: bool, _new_mask: bool) {}
        fn refresh(&mut self, _target: Option<Id>, _magic_on: bool, _is_playing: bool) {}
    }

    #[test]
    fn magic_mask_defaults_draw_no_tint() {
        let mut m = NoSegmenter;
        m.hover(None, None);
        assert_eq!(m.mask_tint(&[], 0.0), MaskTintPicture { image: None, waiting: false });
        assert!(!m.has_hover());
    }

    #[test]
    fn lut_extensions_match_swift() {
        assert_eq!(LUTFileTypes::EXTENSIONS, ["cube", "3dl"]);
    }
}
