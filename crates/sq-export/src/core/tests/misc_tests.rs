// Swift: ExportProgressMathTests.swift, GIFPaletteTests.swift, FrameStillPixelsTests.swift, FrameOutputTests.swift
// (naming, GIF timing), ClipPrefetchTests.swift (scanner), HDRDeliveryAndStemPresetTests.swift (HDR),
// StemMetadataSpecTests.swift (codecs, metadata), TimelineAudioSource

use crate::core::*;
use sq_core_time::{Id, Time, TimeRange};

// MARK: Progress

fn steady(n: i64) -> ExportProgressTracker {
    let mut t = ExportProgressTracker::new();
    for s in 0..=n {
        t.record(s as f64 / 100.0, s as f64);
    }
    t
}

#[test]
fn no_estimate_before_enough_progress() {
    let mut t = ExportProgressTracker::new();
    t.record(0.0, 0.0);
    assert!(t.remaining().is_none());
    t.record(0.005, 1.0); // too early / too little to extrapolate
    assert!(t.remaining().is_none());
}

#[test]
fn steady_rate_gives_exact_estimate() {
    let r = steady(20).remaining().unwrap();
    assert!((r - 80.0).abs() < 2.0, "{r}");
}

#[test]
fn smoothing_damps_a_spike() {
    let s = steady(20);
    let before = s.remaining().unwrap();
    let mut spiky = s;
    spiky.record(0.21, 22.0); // a 2 s stall for 1 % of work
    let after = spiky.remaining().unwrap();
    assert!(after > before - 2.0); // moved by the real elapsed time, not jumped
    assert!(after < before + 20.0);
}

#[test]
fn progress_never_goes_backwards_and_clamps() {
    let mut t = ExportProgressTracker::new();
    t.record(0.5, 10.0);
    t.record(0.3, 11.0);
    assert_eq!(t.progress(), 0.5);
    t.record(1.7, 12.0);
    assert_eq!(t.progress(), 1.0);
    assert_eq!(t.remaining(), Some(0.0));
}

#[test]
fn formats_durations() {
    assert_eq!(ExportProgressTracker::format(0.0), "0:00");
    assert_eq!(ExportProgressTracker::format(59.4), "0:59");
    assert_eq!(ExportProgressTracker::format(61.0), "1:01");
    assert_eq!(ExportProgressTracker::format(3725.0), "1:02:05");
    assert_eq!(ExportProgressTracker::remaining_text(None), "Calculating\u{2026}");
    assert_eq!(ExportProgressTracker::remaining_text(Some(75.0)), "1:15 left");
    assert_eq!(ExportProgressTracker::remaining_text(Some(0.2)), "Almost done");
}

#[test]
fn phases_follow_progress() {
    assert_eq!(ExportProgressTracker::phase(0.0, false), ExportPhase::Preparing);
    assert_eq!(ExportProgressTracker::phase(0.0, true), ExportPhase::Rendering);
    assert_eq!(ExportProgressTracker::phase(0.5, true), ExportPhase::Rendering);
    assert_eq!(ExportProgressTracker::phase(0.995, true), ExportPhase::Finishing);
    assert_eq!(ExportPhase::Finishing.title(), "Finishing");
}

#[test]
fn throttle_limits_update_rate() {
    let mut th = ProgressThrottle::new(0.1);
    let a = th.accept(0.01, 0.0);
    let b = th.accept(0.02, 0.05);
    let c = th.accept(0.03, 0.11);
    let d = th.accept(1.0, 0.12); // completion always passes
    assert!(a && !b && c && d);
}

// MARK: GIF palette

fn rgba(w: usize, h: usize, f: impl Fn(usize, usize) -> (u8, u8, u8)) -> Vec<u8> {
    let mut out = Vec::new();
    for y in 0..h {
        for x in 0..w {
            let c = f(x, y);
            out.extend([c.0, c.1, c.2, 255]);
        }
    }
    out
}

fn quant(px: &[u8], w: usize, h: usize) -> GifPaletteFrame {
    GifPalette::quantize(px, w, h, w * 4, 0, 1, 2, 256)
}

#[test]
fn few_colors_stay_exact() {
    let px = rgba(4, 2, |x, y| {
        if x < 2 {
            (255, 0, 0)
        } else if y == 0 {
            (0, 0, 255)
        } else {
            (12, 200, 99)
        }
    });
    let f = quant(&px, 4, 2);
    assert_eq!(f.colors.len(), 3);
    for (i, idx) in f.indices.iter().enumerate() {
        let c = f.colors[usize::from(*idx)];
        assert_eq!([c.0, c.1, c.2], px[i * 4..i * 4 + 3]);
    }
}

#[test]
fn bgra_offsets_read_the_right_channels() {
    let px = [10u8, 20, 30, 255]; // B G R A
    let f = GifPalette::quantize(&px, 1, 1, 4, 2, 1, 0, 256);
    assert!(f.colors.len() == 1 && f.colors[0] == (30, 20, 10));
}

#[test]
fn gradient_uses_at_most_256_colors_and_stays_close() {
    let (w, h) = (256, 64);
    let px = rgba(w, h, |x, y| (x as u8, ((y * 4) & 255) as u8, (255 - x) as u8));
    let f = quant(&px, w, h);
    assert!(f.colors.len() <= 256 && f.colors.len() > 200, "{}", f.colors.len());
    let (mut sum, mut worst) = (0.0, 0i32);
    for i in 0..w * h {
        let c = f.colors[usize::from(f.indices[i])];
        let d = [
            (i32::from(c.0) - i32::from(px[i * 4])).abs(),
            (i32::from(c.1) - i32::from(px[i * 4 + 1])).abs(),
            (i32::from(c.2) - i32::from(px[i * 4 + 2])).abs(),
        ]
        .into_iter()
        .max()
        .unwrap();
        sum += f64::from(d);
        worst = worst.max(d);
    }
    assert!(sum / ((w * h) as f64) < 10.0);
    assert!(worst < 40);
}

#[test]
fn same_frame_same_palette() {
    let px = rgba(64, 64, |x, y| ((x * 4) as u8, (y * 4) as u8, ((x ^ y) * 4) as u8));
    assert_eq!(quant(&px, 64, 64), quant(&px, 64, 64));
    assert_eq!(GifPalette::quantize(&[], 0, 0, 0, 0, 1, 2, 256), GifPaletteFrame { indices: vec![], colors: vec![] });
}

// MARK: Still pixels

/// f32 to binary16 bits (test helper; values here are exact in half).
fn half(f: f32) -> u16 {
    if f == 0.0 {
        return 0;
    }
    let b = f.to_bits();
    let sign = ((b >> 16) & 0x8000) as u16;
    let e = ((b >> 23) & 0xFF) as i32 - 127 + 15;
    sign | (e as u16) << 10 | ((b >> 13) & 0x3FF) as u16
}

fn pixels(rgba: &[[f32; 4]]) -> Vec<u8> {
    rgba.iter().flatten().flat_map(|v| half(*v).to_le_bytes()).collect()
}

#[test]
fn half_bits_decode() {
    for v in [0.0f32, 1.0, 0.5, 0.25, -2.0, 1024.0, 0.000061035156] {
        assert_eq!(FrameStillPixels::float(half(v)), v);
    }
    assert_eq!(FrameStillPixels::float(0x0001), 1.0 / 16_777_216.0); // smallest subnormal 2^-24
    assert_eq!(FrameStillPixels::float(0x7C00), f32::INFINITY);
}

#[test]
fn png_is_opaque_bt709() {
    let px = pixels(&[[1.0, 0.5, 0.0, 0.5], [0.018, 0.25, 1.0, 1.0]]);
    let img = FrameStillPixels::image(&px, 2, 1, 16, FrameStillFormat::Png).unwrap();
    assert!(img.bits_per_channel == 8 && !img.has_alpha && !img.is_float);
    // Premultiplied values go through the curve as they are (opaque formats keep the composite over black).
    let e = |x: f32| (FrameStillPixels::oetf(x) * 255.0).round() as u8;
    assert_eq!(img.bytes, [255, e(0.5), 0, 255, e(0.018), e(0.25), 255, 255]);
}

#[test]
fn alpha_formats_are_straight() {
    let px = pixels(&[[0.25, 0.125, 0.0, 0.5], [0.0, 0.0, 0.0, 0.0]]);
    let png = FrameStillPixels::image(&px, 2, 1, 16, FrameStillFormat::PngAlpha).unwrap();
    let e = |x: f32| (FrameStillPixels::oetf(x) * 255.0).round() as u8;
    assert!(png.has_alpha);
    assert_eq!(png.bytes, [e(0.5), e(0.25), 0, 128, 0, 0, 0, 0]);
    let tiff = FrameStillPixels::image(&px, 2, 1, 16, FrameStillFormat::Tiff16Alpha).unwrap();
    assert!(tiff.bits_per_channel == 16 && tiff.bytes.len() == 16);
    assert_eq!(
        u16::from_le_bytes([tiff.bytes[0], tiff.bytes[1]]),
        (FrameStillPixels::oetf(0.5) * 65535.0).round() as u16
    );
    assert_eq!(u16::from_le_bytes([tiff.bytes[6], tiff.bytes[7]]), 32768); // 0.5 * 65535 rounded
}

#[test]
fn exr_keeps_the_halves_and_rows_are_packed() {
    // Two rows with padding between them: the output is tightly packed.
    let mut px = pixels(&[[2.0, 0.5, 0.25, 1.0]]);
    px.extend([0u8; 8]);
    px.extend(pixels(&[[0.0, 0.0, 1.0, 0.5]]));
    px.extend([0u8; 8]);
    let img = FrameStillPixels::image(&px, 1, 2, 16, FrameStillFormat::Exr).unwrap();
    assert!(img.is_float && img.has_alpha && img.bytes.len() == 16);
    assert_eq!(FrameStillPixels::float(u16::from_le_bytes([img.bytes[0], img.bytes[1]])), 2.0); // over-range light stays
    assert_eq!(FrameStillPixels::float(u16::from_le_bytes([img.bytes[12], img.bytes[13]])), 1.0);
}

#[test]
fn too_small_input_is_rejected() {
    assert!(FrameStillPixels::image(&[0u8; 8], 2, 1, 16, FrameStillFormat::Png).is_none());
    assert_eq!(
        StillImage { bytes: vec![], width: 3, height: 1, bits_per_channel: 16, is_float: false, has_alpha: false }
            .bytes_per_row(),
        24
    );
}

// MARK: Naming and GIF timing

#[test]
fn gif_delays_alternate_and_sum_to_the_duration() {
    assert_eq!(GifTiming::delays_centiseconds(Time::new(1, 24), 6), [4, 4, 5, 4, 4, 4]);
    for fd in [Time::new(1, 24), Time::new(1, 30), Time::new(1001, 30000), Time::new(1, 25), Time::new(1, 15)] {
        for frames in [1usize, 7, 48, 120] {
            let delays = GifTiming::delays_centiseconds(fd, frames);
            assert_eq!(delays.len(), frames);
            let exact = frames as f64 * fd.value() as f64 / fd.timescale() as f64 * 100.0;
            assert!((delays.iter().sum::<i64>() as f64 - exact).abs() <= 0.5, "{fd:?} {frames}");
        }
    }
}

#[test]
fn gif_delays_of_nothing() {
    assert!(GifTiming::delays_centiseconds(Time::new(1, 24), 0).is_empty());
    assert!(GifTiming::delays_centiseconds(Time::new(0, 24), 3).is_empty());
}

#[test]
fn sequence_names_are_sanitized_and_padded() {
    assert_eq!(ImageSequenceNaming::file_name("a/b:c", 7, 4, "png"), "a-b-c_0007.png");
    assert_eq!(ImageSequenceNaming::digits(0, 10), 4);
    assert_eq!(ImageSequenceNaming::digits(0, 10_000), 4);
    assert_eq!(ImageSequenceNaming::digits(0, 10_001), 5);
    assert_eq!(ImageSequenceNaming::digits(99_990, 20), 6);
    assert_eq!(
        ImageSequenceNaming::file_names("Shot", 8, 3, "tiff"),
        ["Shot_0008.tiff", "Shot_0009.tiff", "Shot_0010.tiff"]
    );
    assert!(ImageSequenceNaming::file_names("x", 0, 0, "png").is_empty());
}

#[test]
fn frame_output_settings() {
    let mut s = ExportPreset::IMAGE_SEQUENCE.settings();
    assert_eq!(s.frame_output, Some(FrameOutput::Sequence(FrameStillFormat::PngAlpha)));
    assert!(s.validate().is_empty());
    s.video.width = 1081; // pictures have no chroma subsampling
    assert!(s.validate().is_empty());
    assert_eq!(FrameOutput::Gif.display_name(), "Animated GIF");
    assert_eq!(
        FrameOutput::Sequence(FrameStillFormat::Exr).display_name(),
        "Image sequence \u{B7} EXR (half float, linear)"
    );
    assert_eq!(FrameStillFormat::available().len(), 6);
    assert!(FrameStillFormat::Exr.keeps_alpha() && !FrameStillFormat::Jpeg.keeps_alpha());
    assert_eq!(FrameStillFormat::Jpeg.file_extension(), "jpg");
    assert_eq!(ExportPreset::GIF.settings().frame_output, Some(FrameOutput::Gif));
}

#[test]
fn constant_quality_replaces_the_bitrate() {
    let mut s = ExportSettings::default();
    s.video.set_constant_quality(Some(0.5));
    assert!(s.video.uses_constant_quality() && !s.video.uses_constant_bitrate());
    s.video.set_constant_quality(Some(0.0));
    assert_eq!(s.video.constant_quality(), Some(0.05));
}

// MARK: HDR delivery

#[test]
fn mastering_bytes_are_big_endian_and_exact() {
    let d = HdrDelivery::new(HdrTransfer::Pq, 1000.0, 400.0, 0.005);
    let b = d.mastering_display_data();
    assert_eq!(b.len(), 24);
    // Green x 0.265 / 0.00002 = 13250 = 0x33C2; white point x 0.3127 -> 15635 = 0x3D13.
    assert_eq!(b[0..2], [0x33, 0xC2]);
    assert_eq!(b[12..14], [0x3D, 0x13]);
    // 1000 nits = 10_000_000 = 0x00989680; 0.005 nit = 50 = 0x32.
    assert_eq!(b[16..20], [0x00, 0x98, 0x96, 0x80]);
    assert_eq!(b[20..24], [0, 0, 0, 0x32]);
}

#[test]
fn light_level_and_clamping() {
    let d = HdrDelivery::new(HdrTransfer::Pq, 99_999.0, 50_000.0, 0.005);
    assert!(d.peak_nits == 10_000.0 && d.frame_average_nits == 10_000.0);
    assert_eq!(d.content_light_level_data(), [0x27, 0x10, 0x27, 0x10]);
    assert_eq!(HdrDelivery::new(HdrTransfer::Pq, 10.0, 400.0, 0.005).peak_nits, 100.0);
}

#[test]
fn hdr_absent_by_default_round_trips_and_reads_tolerantly() {
    let mut s = ExportSettings::default();
    assert!(s.hdr_delivery.is_none());
    s.hdr_delivery = Some(HdrDelivery::new(HdrTransfer::Hlg, 600.0, 400.0, 0.005));
    let back: ExportSettings = serde_json::from_slice(&serde_json::to_vec(&s).unwrap()).unwrap();
    assert_eq!(back.hdr_delivery, s.hdr_delivery);
    let d: HdrDelivery = serde_json::from_str(r#"{"transfer": 5, "peakNits": 700}"#).unwrap();
    assert!(d.transfer == HdrTransfer::Pq && d.peak_nits == 700.0 && d.frame_average_nits == 400.0);
}

#[test]
fn suggested_transfer_prefers_pq() {
    use sq_core_model::TargetSpace::*;
    assert_eq!(HdrTransfer::suggested([Rec709, Rec2020HLG, Rec2020PQ]), Some(HdrTransfer::Pq));
    assert_eq!(HdrTransfer::suggested([Rec2020HLG]), Some(HdrTransfer::Hlg));
    assert_eq!(HdrTransfer::suggested([Rec709, Rec2020]), None);
    assert_eq!(HdrTransfer::Pq.title(), "PQ (HDR10)");
}

#[test]
fn hdr_to_sdr_clamps() {
    assert_eq!(HdrToSdr::new(9.0, true).exposure_stops, 4.0);
    assert!(HdrToSdr::new(0.0, false).is_default() && !HdrToSdr::default().is_default());
}

// MARK: Codecs, metadata

#[test]
fn pro_res_lt_and_proxy() {
    assert!(VideoCodec::ProRes422LT.is_pro_res() && VideoCodec::ProRes422Proxy.is_mastering());
    assert_eq!(VideoCodec::ProRes422LT.display_name(), "ProRes 422 LT");
    let mut s = ExportSettings::default();
    s.video.codec = VideoCodec::ProRes422LT;
    let lt = s.estimated_video_bits_per_second();
    s.video.codec = VideoCodec::ProRes422;
    assert!(lt < s.estimated_video_bits_per_second());
    assert!(s.validate().is_empty());
    assert_eq!(serde_json::to_string(&VideoCodec::ProRes422HQ).unwrap(), "\"prores422HQ\"");
    for c in VideoCodec::ALL {
        assert_eq!(serde_json::to_string(&c).unwrap(), format!("\"{}\"", c.raw_value()));
    }
}

#[test]
fn metadata_full_comment_and_round_trip() {
    let m = ExportMetadata::new("Film", "Cut 3", Some(0.0), "0:00 Intro\n0:20 Main");
    assert_eq!(m.full_comment(), "Cut 3\n\n0:00 Intro\n0:20 Main");
    assert_eq!(ExportMetadata::new("", "", None, "0:00 A").full_comment(), "0:00 A");
    assert!(ExportMetadata::default().is_empty());
    let mut s = ExportSettings::default();
    s.metadata = Some(m.clone());
    let back: ExportSettings = serde_json::from_slice(&serde_json::to_vec(&s).unwrap()).unwrap();
    assert_eq!(back.metadata, Some(m));
    let old: ExportSettings = serde_json::from_slice(&serde_json::to_vec(&ExportSettings::default()).unwrap()).unwrap();
    assert!(old.metadata.is_none());
}

// MARK: Prefetch scanner

mod prefetch {
    use super::*;

    const FD: Time = Time::new(1, 30);

    /// (clip id, media, source start frame, frames, timeline start frame, generator)
    type C = (u128, Id, i64, i64, i64, bool);

    fn layers(tracks: &[Vec<C>], t: Time) -> Vec<PrefetchLayer> {
        let f = t.frame_index(FD);
        let mut out = Vec::new();
        for track in tracks {
            for &(id, media, src, frames, at, generator) in track {
                if f >= at && f < at + frames {
                    out.push(PrefetchLayer {
                        clip: Id::from_u128(id),
                        media,
                        source_time: Time::new(src + f - at, 30),
                        is_generator: generator,
                    });
                }
            }
        }
        out
    }

    fn scan(tracks: &[Vec<C>], start: i64, count: usize, lead: usize, to: &[i64]) -> Vec<Vec<PrefetchHint>> {
        let mut s = ClipPrefetchScanner::new(Time::new(start, 30), FD, count, lead);
        to.iter().map(|f| s.advance(Time::new(*f, 30), &mut |t| layers(tracks, t))).collect()
    }

    fn hint(media: Id, src: i64) -> PrefetchHint {
        PrefetchHint { media, source_time: Time::new(src, 30) }
    }

    fn ab() -> (Id, Id, Vec<Vec<C>>) {
        let (a, b) = (Id::from_u128(100), Id::from_u128(200));
        (a, b, vec![vec![(1, a, 0, 30, 0, false), (2, b, 50, 30, 30, false)]])
    }

    #[test]
    fn hints_the_next_clip_start_once_it_is_within_the_lead() {
        let (_, b, tl) = ab();
        let h = scan(&tl, 0, 60, 10, &[0, 19, 20, 21, 40]);
        assert!(h[0].is_empty() && h[1].is_empty());
        assert_eq!(h[2], [hint(b, 50)]);
        assert!(h[3].is_empty() && h[4].is_empty());
    }

    #[test]
    fn a_jump_cut_on_one_media_is_hinted() {
        let a = Id::from_u128(100);
        let tl = vec![vec![(1, a, 0, 30, 0, false), (2, a, 40, 20, 30, false)]];
        assert_eq!(scan(&tl, 0, 50, 10, &[20]), [vec![hint(a, 40)]]);
    }

    #[test]
    fn clips_drawn_at_the_start_are_not_hinted() {
        let (_, _, tl) = ab();
        // A segment that starts inside b: its first frame is fetched by the render itself.
        assert_eq!(scan(&tl, 35, 20, 10, &[35, 45]), [vec![], vec![]]);
    }

    #[test]
    fn never_looks_past_the_last_frame() {
        let (_, _, tl) = ab();
        assert_eq!(scan(&tl, 0, 30, 10, &[20, 29]), [vec![], vec![]]);
    }

    #[test]
    fn generators_are_not_hinted() {
        let a = Id::from_u128(100);
        let tl = vec![vec![(1, a, 0, 60, 0, false)], vec![(2, Id::from_u128(300), 0, 10, 30, true)]];
        assert_eq!(scan(&tl, 0, 60, 10, &[20, 25]), [vec![], vec![]]);
    }

    #[test]
    fn a_clip_starting_over_a_continuing_clip_is_hinted_alone() {
        let (a, b) = (Id::from_u128(100), Id::from_u128(200));
        let tl = vec![vec![(1, a, 0, 60, 0, false)], vec![(2, b, 7, 10, 30, false)]];
        assert_eq!(scan(&tl, 0, 60, 10, &[20]), [vec![hint(b, 7)]]);
    }

    #[test]
    fn a_jump_forward_past_the_scan_restarts_it_there() {
        let (_, b, tl) = ab();
        let mut s = ClipPrefetchScanner::new(Time::ZERO, FD, 60, 10);
        let mut f = |t: Time| layers(&tl, t);
        assert_eq!(s.advance(Time::new(20, 30), &mut f), [hint(b, 50)]);
        // Jumping on to frame 45 (inside b) re-seeds there: b is drawn at the new start, so nothing is hinted.
        assert!(s.advance(Time::new(45, 30), &mut f).is_empty());
        // Moving back never rewinds the scan (export only moves forward).
        assert!(s.advance(Time::new(5, 30), &mut f).is_empty());
    }
}

// MARK: Timeline audio source

mod timeline_audio {
    use super::*;
    use crate::core::tests::BufferSource;

    /// A feed that serves a ramp (left = n, right = -n) in blocks of 100 frames after dropping `latency` frames.
    struct Ramp {
        next: i64,
        ring: Vec<(f32, f32)>,
        latency: usize,
        seeks: Vec<i64>,
        end: i64,
    }

    impl MixFeed for Ramp {
        fn seek(&mut self, frame: i64) {
            self.seeks.push(frame);
            self.next = frame;
            self.ring.clear();
        }
        fn prime(&mut self) -> usize {
            self.fill(1);
            self.latency
        }
        fn fill(&mut self, max_blocks: usize) -> usize {
            let mut blocks = 0;
            while blocks < max_blocks && self.next < self.end {
                for _ in 0..100 {
                    self.ring.push((self.next as f32, -(self.next as f32)));
                    self.next += 1;
                }
                blocks += 1;
            }
            blocks
        }
        fn available_to_read(&self) -> usize {
            self.ring.len()
        }
        fn pop(&mut self, left: &mut [f32], right: &mut [f32]) {
            for i in 0..left.len() {
                (left[i], right[i]) = self.ring.remove(0);
            }
        }
    }

    fn ramp(latency: usize) -> Ramp {
        Ramp { next: 0, ring: Vec::new(), latency, seeks: Vec::new(), end: 1_000_000 }
    }

    #[test]
    fn frame_count_rounds_up() {
        let r = TimeRange::new(Time::ZERO, Time::new(1, 3));
        assert_eq!(export_frame_count(r, Time::new(1, 30)), 10);
        assert_eq!(export_frame_count(TimeRange::new(Time::ZERO, Time::new(1, 4)), Time::new(1, 30)), 8);
        assert_eq!(export_frame_count(TimeRange::new(Time::ZERO, Time::ZERO), Time::new(1, 30)), 0);
        assert_eq!(export_frame_count(r, Time::ZERO), 0);
    }

    #[test]
    fn reads_the_range_in_order_from_its_start_frame_and_drops_the_latency() {
        // Starts at 1/100 s = 480 frames; 0.002 s = 96 frames long.
        let range = TimeRange::new(Time::new(1, 100), Time::new(2, 1000));
        let mut src = TimelineAudioSource::new(ramp(30), 2, range);
        assert_eq!(src.total_frames, 96);
        let a = src.next_chunk(50).unwrap().unwrap();
        assert_eq!((a.channels, a.frame_count()), (2, 50));
        // 30 frames of latency are dropped from the 480 start.
        assert_eq!(a.samples[0], 510.0);
        assert_eq!(a.samples[1], -510.0);
        let b = src.next_chunk(50).unwrap().unwrap();
        assert_eq!(b.frame_count(), 46);
        assert_eq!(b.samples[0], 560.0);
        assert!(src.next_chunk(50).unwrap().is_none());
        src.rewind().unwrap();
        assert_eq!(src.next_chunk(10).unwrap().unwrap().samples[0], 510.0);
        assert_eq!(src.feed().seeks, [480, 480]);
    }

    #[test]
    fn mono_sequences_keep_one_channel_and_a_short_feed_ends_the_stream() {
        let mut feed = ramp(0);
        feed.end = 150;
        let mut src = TimelineAudioSource::new(feed, 1, TimeRange::new(Time::ZERO, Time::new(1, 1)));
        let c = src.next_chunk(1000).unwrap().unwrap();
        assert_eq!((c.channels, c.frame_count()), (1, 200)); // two blocks of 100: the feed ran dry after 150 -> 200
        assert_eq!(c.samples[199], 199.0);
        assert!(src.next_chunk(1000).unwrap().is_none());
        assert_eq!(src.sample_rate(), 48_000);
    }

    #[test]
    fn as_rewindable_reaches_rewind_through_the_trait_object() {
        let mut b = BufferSource::new(48_000, 1, vec![0.5; 4]);
        let dynamic: &mut dyn AudioSource = &mut b;
        assert!(dynamic.as_rewindable().is_some());
    }
}
