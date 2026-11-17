// Swift: SlipTwoUp.swift
//! Pure layout and wording of the Slip two-up viewer, plus the packing of both pictures into one image slot.

use crate::cg::RectExt;
use crate::monitor_panel::MonitorPanel;
use sq_core_time::Time;
use sq_draw::canvas::Canvas;
use sq_draw::theme::spacing;
use sq_draw::{Color, RgbaImage, TextAlign};
use sq_uikit::controls_grid::CGRect;

/// Layout and wording of the Slip two-up viewer.
pub enum SlipTwoUpLayout {}

impl SlipTwoUpLayout {
    /// Height of the readout strip under the two pictures.
    pub const READOUT_HEIGHT: f64 = 28.0;

    /// Left (first frame) and right (last frame) picture frames inside `bounds`, flipped coordinates.
    pub fn pane_frames(bounds: CGRect, gap: f64) -> (CGRect, CGRect) {
        let h = (bounds.height - Self::READOUT_HEIGHT - gap).max(0.0);
        let w = ((bounds.width - gap * 3.0) / 2.0).max(0.0);
        (
            CGRect::new(bounds.min_x() + gap, bounds.min_y() + gap, w, h),
            CGRect::new(bounds.min_x() + gap * 2.0 + w, bounds.min_y() + gap, w, h),
        )
    }

    /// Slip offset in whole frames (rounded, signed).
    pub fn whole_frames(offset: Time, frame_duration: Time) -> i64 {
        let fd = frame_duration;
        if fd.value() == 0 || offset.timescale() == 0 {
            return 0;
        }
        let r = offset.value() as f64 * fd.timescale() as f64 / (offset.timescale() as f64 * fd.value() as f64);
        r.round() as i64
    }

    /// "Slip -4 f", "Slip +12 f", "Slip 0 f".
    pub fn readout(offset_frames: i64) -> String {
        format!("Slip {}{} f", if offset_frames > 0 { "+" } else { "" }, offset_frames)
    }

    /// Both pictures side by side in one RGBA image (left half the first frame, right half the last), each scaled to
    /// `half` (nearest sample); a missing picture stays black. The canvas shows the halves with source rects
    /// (0, 0, 0.5, 1) and (0.5, 0, 1, 1).
    pub fn pack(head: Option<&RgbaImage>, tail: Option<&RgbaImage>, half: (usize, usize)) -> RgbaImage {
        let w = half.0.max(1);
        let h = half.1.max(1);
        let mut out = vec![0u8; w * 2 * h * 4];
        for i in (3..out.len()).step_by(4) {
            out[i] = 255;
        }
        for (n, img) in [head, tail].into_iter().enumerate() {
            let Some(img) = img else { continue };
            if img.width == 0 || img.height == 0 || img.pixels.len() < img.width * img.height * 4 {
                continue;
            }
            for y in 0..h {
                let sy = (img.height - 1).min(y * img.height / h);
                for x in 0..w {
                    let sx = (img.width - 1).min(x * img.width / w);
                    let s = (sy * img.width + sx) * 4;
                    let d = (y * w * 2 + n * w + x) * 4;
                    out[d] = img.pixels[s];
                    out[d + 1] = img.pixels[s + 1];
                    out[d + 2] = img.pixels[s + 2];
                    out[d + 3] = 255;
                }
            }
        }
        RgbaImage { width: w * 2, height: h, pixels: out }
    }
}

/// What the Program monitor shows during a Slip drag: the clip's first and last frame side by side with their
/// timecodes and the slip readout. `slot` holds both pictures packed by [`SlipTwoUpLayout::pack`]; `None` while they are
/// still decoding (black panes). Trim mode uses the same two-up for the frames before and after the edit.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SlipTwoUpPicture {
    /// Timecode of the first frame.
    pub head_timecode: String,
    /// Timecode of the last frame.
    pub tail_timecode: String,
    /// The slip in whole frames.
    pub offset_frames: i64,
    /// Image slot with both panes packed.
    pub slot: Option<usize>,
    /// Title of the left pane.
    pub head_title: String,
    /// Title of the right pane.
    pub tail_title: String,
    /// The line under the panes; `None`: the slip readout of `offset_frames`.
    pub readout: Option<String>,
    /// The left pane is outlined in the accent color (Trim mode's side).
    pub active_head: bool,
    /// The right pane is outlined in the accent color.
    pub active_tail: bool,
}

impl SlipTwoUpPicture {
    /// A slip two-up.
    pub fn new(head_timecode: &str, tail_timecode: &str, offset_frames: i64, slot: Option<usize>) -> SlipTwoUpPicture {
        SlipTwoUpPicture {
            head_timecode: head_timecode.to_string(),
            tail_timecode: tail_timecode.to_string(),
            offset_frames,
            slot,
            head_title: "First frame".to_string(),
            tail_title: "Last frame".to_string(),
            readout: None,
            active_head: false,
            active_tail: false,
        }
    }

    /// Trim mode's two-up: the last frame before the edit and the first after it ("--" where a side has no clip).
    pub fn trim(
        outgoing_timecode: Option<&str>,
        incoming_timecode: Option<&str>,
        outgoing_active: bool,
        incoming_active: bool,
        note: &str,
        slot: Option<usize>,
    ) -> SlipTwoUpPicture {
        let mut p =
            SlipTwoUpPicture::new(outgoing_timecode.unwrap_or("--"), incoming_timecode.unwrap_or("--"), 0, slot);
        p.head_title = "Before the edit".to_string();
        p.tail_title = "After the edit".to_string();
        p.readout = Some(note.to_string());
        p.active_head = outgoing_active;
        p.active_tail = incoming_active;
        p
    }
}

impl MonitorPanel {
    /// The two-up instead of the picture: two bordered panes with "First frame" / "Last frame" and their timecodes on
    /// HUD plates, the readout centered below.
    pub(crate) fn draw_slip_two_up(&self, c: &mut Canvas, two: &SlipTwoUpPicture) {
        let t = self.theme;
        let slot = self.slot;
        c.fill(slot, t.monitor_backdrop());
        let (head, tail) = SlipTwoUpLayout::pane_frames(slot, spacing::SM as f64);
        let inset = (spacing::XS + spacing::XXS) as f64;
        for (i, pane) in [head, tail].into_iter().enumerate() {
            if !(pane.width > 2.0 && pane.height > 2.0) {
                continue;
            }
            c.fill(pane, Color::BLACK);
            if let Some(s) = two.slot {
                // The picture fitted in the pane at the sequence's aspect.
                let aspect = if self.sequence_size.height > 0.0 {
                    self.sequence_size.width / self.sequence_size.height
                } else {
                    16.0 / 9.0
                };
                let mut w = pane.width;
                let mut h = w / aspect;
                if h > pane.height {
                    h = pane.height;
                    w = h * aspect;
                }
                let pic = CGRect::new(pane.mid_x() - w / 2.0, pane.mid_y() - h / 2.0, w, h);
                c.draw_image_slot(
                    s,
                    pic,
                    if i == 0 { [0.0, 0.0, 0.5, 1.0] } else { [0.5, 0.0, 1.0, 1.0] },
                    Color::WHITE,
                );
            }
            let active = if i == 0 { two.active_head } else { two.active_tail };
            c.stroke_polygon(
                &pane.corner_points(),
                if active { 2.0 } else { 1.0 },
                if active { t.accent() } else { t.separator() },
            );
            let title = if i == 0 { &two.head_title } else { &two.tail_title };
            let timecode = if i == 0 { &two.head_timecode } else { &two.tail_timecode };
            for (text, top) in [(title, true), (timecode, false)] {
                let size = c.size_of(text, 11.0, 0);
                let r = CGRect::new(
                    pane.min_x() + inset,
                    if top { pane.min_y() + inset } else { pane.max_y() - inset - 16.0 },
                    size.width + 8.0,
                    16.0,
                );
                c.fill(r, t.viewer_hud());
                c.draw_text_in(text, r, 11.0, t.label2(), TextAlign::Left, 4.0, 0);
            }
        }
        let gap = spacing::SM as f64;
        let readout = two.readout.clone().unwrap_or_else(|| SlipTwoUpLayout::readout(two.offset_frames));
        if readout.is_empty() {
            return;
        }
        c.draw_text_in(
            &readout,
            CGRect::new(
                slot.min_x() + gap,
                slot.max_y() - SlipTwoUpLayout::READOUT_HEIGHT,
                (slot.width - gap * 2.0).max(0.0),
                18.0,
            ),
            11.0,
            t.label2(),
            TextAlign::Center,
            0.0,
            0,
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn panes_sit_side_by_side_above_the_readout() {
        let b = CGRect::new(0.0, 0.0, 830.0, 400.0);
        let (head, tail) = SlipTwoUpLayout::pane_frames(b, 10.0);
        assert!(head.width == 400.0 && tail.width == 400.0);
        assert!(head.min_x() == 10.0 && tail.min_x() == 420.0);
        assert_eq!(head.max_y() + SlipTwoUpLayout::READOUT_HEIGHT, b.height);
    }

    #[test]
    fn tiny_view_never_goes_negative() {
        let (head, _) = SlipTwoUpLayout::pane_frames(CGRect::new(0.0, 0.0, 10.0, 10.0), 10.0);
        assert!(head.width == 0.0 && head.height == 0.0);
    }

    #[test]
    fn readout_wording() {
        assert_eq!(SlipTwoUpLayout::readout(12), "Slip +12 f");
        assert_eq!(SlipTwoUpLayout::readout(-3), "Slip -3 f");
        assert_eq!(SlipTwoUpLayout::readout(0), "Slip 0 f");
    }

    #[test]
    fn offset_rounds_to_whole_frames() {
        let fd = Time::new(1, 30);
        assert_eq!(SlipTwoUpLayout::whole_frames(Time::new(12, 30), fd), 12);
        assert_eq!(SlipTwoUpLayout::whole_frames(Time::new(-3, 30), fd), -3);
        assert_eq!(SlipTwoUpLayout::whole_frames(Time::ZERO, fd), 0);
    }

    #[test]
    fn pack_puts_the_first_frame_left_and_the_last_right() {
        let red = RgbaImage::filled(4, 2, Color::rgb(1.0, 0.0, 0.0));
        let blue = RgbaImage::filled(8, 4, Color::rgb(0.0, 0.0, 1.0));
        let img = SlipTwoUpLayout::pack(Some(&red), Some(&blue), (3, 2));
        assert!(img.width == 6 && img.height == 2);
        let px = |x: usize, y: usize| img.pixels[(y * 6 + x) * 4..(y * 6 + x) * 4 + 4].to_vec();
        assert!(px(0, 0) == [255, 0, 0, 255] && px(2, 1) == [255, 0, 0, 255]);
        assert!(px(3, 0) == [0, 0, 255, 255] && px(5, 1) == [0, 0, 255, 255]);
    }

    #[test]
    fn pack_leaves_a_missing_picture_black() {
        let white = RgbaImage::filled(2, 2, Color::WHITE);
        let img = SlipTwoUpLayout::pack(None, Some(&white), (2, 2));
        assert_eq!(img.pixels[0..4], [0, 0, 0, 255]);
        assert_eq!(img.pixels[8..12], [255, 255, 255, 255]);
    }

    #[test]
    fn trim_two_up_names_the_sides_and_marks_the_trimmed_one() {
        let p = SlipTwoUpPicture::trim(Some("00:00:02:10"), None, true, false, "Ripple", None);
        assert!(p.head_title == "Before the edit" && p.tail_title == "After the edit");
        assert!(p.head_timecode == "00:00:02:10" && p.tail_timecode == "--");
        assert!(p.readout.as_deref() == Some("Ripple") && p.active_head && !p.active_tail);
        let slip = SlipTwoUpPicture::new("a", "b", 2, None);
        assert!(slip.head_title == "First frame" && slip.readout.is_none() && !slip.active_head);
    }

    // Swift SlipTwoUpLayoutTests.monitorDrawsBothPanesFromTheSlotInsteadOfThePicture
    #[test]
    fn monitor_draws_both_panes_from_the_slot_instead_of_the_picture() {
        use crate::test_support::{draw, panel};
        use sq_draw::QuadKind;
        use sq_draw::monitor::monitor_modes::MonitorMode;
        let mut p = panel(MonitorMode::Program);
        p.has_picture = true;
        p.slip_two_up = Some(SlipTwoUpPicture::new("00:00:01:00", "00:00:04:00", -4, Some(1)));
        let c = draw(&mut p);
        let mut u1: Vec<f32> =
            c.list.quads().iter().filter(|q| q.kind == QuadKind::Image && q.slot == 1.0).map(|q| q.uv[2]).collect();
        u1.sort_by(f32::total_cmp);
        assert_eq!(u1, vec![0.5, 1.0]);
        assert!(!c.list.quads().iter().any(|q| q.kind == QuadKind::Video));
    }

    // Swift SlipTwoUpLayoutTests.trimTwoUpOutlinesTheActivePaneInTheAccent
    #[test]
    fn trim_two_up_outlines_the_active_pane_in_the_accent() {
        use crate::test_support::{draw, panel};
        use sq_draw::monitor::monitor_modes::MonitorMode;
        let strokes = |active: bool| {
            let mut p = panel(MonitorMode::Program);
            p.slip_two_up = Some(SlipTwoUpPicture::trim(Some("x"), Some("y"), active, active, "", None));
            let accent = p.theme.accent();
            draw(&mut p).list.quads().iter().filter(|q| q.color == accent).count()
        };
        assert!(strokes(true) > strokes(false));
    }
}
