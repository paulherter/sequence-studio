// Swift: SQAppShell/TimelineEditorDialogs.swift (saveSelectionAsTemplate), MacShellSupport.thumbnailPNG
//! The preview image of a saved title template: the Program frame at the playhead, scaled to 320 px wide, as a PNG.

use crate::LinearImage;
use crate::editor_dialogs::{MakePreset, Save};
use sq_export::core::{FrameStillFormat, FrameStillPixels};
use sq_library::title_template_preset::TitleTemplatePreset;

/// The width of the Library thumbnail (Swift: 320 px).
const WIDTH: usize = 320;

/// A template waiting for the Program frame that becomes its preview image.
pub(crate) struct PendingTemplate {
    pub name: String,
    pub template: sq_core_model::TitleTemplate,
    /// Library folder to file the template in ("/" path), `None` = top level.
    pub folder: Option<String>,
}

impl PendingTemplate {
    /// The Library save of this template with `thumbnail` (`None`: the row shows an icon). `asked`: a preview image was
    /// wanted, so the status line says when it could not be made.
    pub fn into_save(self, thumbnail: Option<Vec<u8>>, asked: bool) -> Save {
        let PendingTemplate { name, template, folder } = self;
        let mut done = format!("Saved template \u{201c}{name}\u{201d}. Find it in the Library under Titles.");
        if asked && thumbnail.is_none() {
            done.push_str(" No preview image could be made.");
        }
        let preset = TitleTemplatePreset { template, thumbnail };
        let make: MakePreset =
            Box::new(move |id, at| preset.preset_item_in(&name, folder.as_deref(), id, at).map_err(|e| e.to_string()));
        Save { make, done, failure: "The template could not be saved: " }
    }
}

/// `image` (linear half floats) as an 8-bit PNG at most [`WIDTH`] wide, aspect kept; `None` for an empty picture.
pub(crate) fn thumbnail_png(image: &LinearImage) -> Option<Vec<u8>> {
    let still =
        FrameStillPixels::image(&image.bytes, image.width, image.height, image.width * 8, FrameStillFormat::PngAlpha)?;
    let (sw, sh) = (still.width, still.height);
    let w = sw.min(WIDTH);
    let h = (sh * w / sw).max(1);
    // Box filter: every output pixel averages the source pixels it covers.
    let mut out = vec![0u8; w * h * 4];
    for y in 0..h {
        let (y0, y1) = (y * sh / h, ((y + 1) * sh / h).max(y * sh / h + 1).min(sh));
        for x in 0..w {
            let (x0, x1) = (x * sw / w, ((x + 1) * sw / w).max(x * sw / w + 1).min(sw));
            let mut sum = [0u32; 4];
            for sy in y0..y1 {
                for sx in x0..x1 {
                    let at = (sy * sw + sx) * 4;
                    for (c, s) in sum.iter_mut().enumerate() {
                        *s += u32::from(still.bytes[at + c]);
                    }
                }
            }
            let n = ((y1 - y0) * (x1 - x0)) as u32;
            for (c, s) in sum.iter().enumerate() {
                out[(y * w + x) * 4 + c] = (s / n) as u8;
            }
        }
    }
    let mut png_bytes = Vec::new();
    let mut enc = png::Encoder::new(&mut png_bytes, w as u32, h as u32);
    enc.set_color(png::ColorType::Rgba);
    enc.set_depth(png::BitDepth::Eight);
    enc.write_header().ok()?.write_image_data(&out).ok()?;
    Some(png_bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gray(width: usize, height: usize) -> LinearImage {
        // Half 1.0 = 0x3C00, half 0.0 = 0; opaque mid gray would be 0x3800 (0.5).
        let px = [0x00u8, 0x38, 0x00, 0x38, 0x00, 0x38, 0x00, 0x3C];
        LinearImage { width, height, bytes: px.iter().copied().cycle().take(width * height * 8).collect() }
    }

    #[test]
    fn a_frame_becomes_a_320_px_png_with_its_aspect() {
        let png_bytes = thumbnail_png(&gray(1920, 1080)).expect("png");
        let mut reader = png::Decoder::new(std::io::Cursor::new(png_bytes)).read_info().expect("a PNG");
        let mut buf = vec![0; reader.output_buffer_size().expect("size")];
        let info = reader.next_frame(&mut buf).expect("frame");
        assert_eq!((info.width, info.height), (320, 180));
        assert!(buf[0] > 0 && buf[0] < 255 && buf[3] == 255, "a gray, opaque pixel: {:?}", &buf[..4]);
    }

    #[test]
    fn a_small_frame_is_not_enlarged_and_an_empty_one_makes_no_png() {
        assert!(thumbnail_png(&gray(64, 36)).is_some());
        assert!(thumbnail_png(&LinearImage { width: 0, height: 0, bytes: Vec::new() }).is_none());
    }

    #[test]
    fn a_template_without_a_picture_says_so() {
        let pending = |t: &str| PendingTemplate {
            name: t.into(),
            template: sq_core_model::TitleTemplate::new(
                sq_core_time::Id::from_u128(9),
                t,
                None,
                sq_core_model::Timeline::new(
                    sq_core_time::Id::from_u128(8),
                    t,
                    sq_core_model::SequenceFormat::new(sq_core_time::Time::new(1, 30)),
                    vec![sq_core_model::Track::new(sq_core_time::Id::from_u128(7), sq_core_model::TrackKind::Video)],
                ),
                Vec::new(),
                None,
            ),
            folder: None,
        };
        assert!(pending("A").into_save(None, true).done.ends_with("No preview image could be made."));
        assert!(pending("A").into_save(None, false).done.ends_with("under Titles."), "none was wanted: no note");
        let with = pending("B").into_save(Some(vec![1, 2, 3]), true);
        assert_eq!(with.done, "Saved template \u{201c}B\u{201d}. Find it in the Library under Titles.");
        let at = sq_core_time::Timestamp::from_unix_seconds(0.0);
        assert!((with.make)(sq_core_time::Id::from_u128(1), at).is_ok(), "the thumbnail rides in the payload");
    }
}
