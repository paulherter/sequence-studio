//! Encode half of the FFmpeg shim: H.264 / HEVC (hardware first) or ProRes video, AAC or PCM audio into MP4 / MOV,
//! audio-only files, animated GIF and stills. Port of the encode side of `CSQFFmpeg` (`encode.cpp`, `still.cpp`).
//! The `Encoder` type is the safe surface; `sq-export` drives it. Unsafe code is confined to `raw` and `encoder`.

mod candidates;
mod caps;
mod encoder;
mod options;
mod raw;

pub use candidates::{Candidates, Platform, candidates, first_available};
pub use caps::{EncoderCaps, Missing, Probe, ProbeKind, ProbeState, Wish, cached, caps_of, finish_warm_up, missing, probe, warm_up};
pub use encoder::{ENCODER_NOT_FOUND, EncodeConfig, Encoder, PixelLayout, StillCodec, Tags, VideoFacts, write_still};
pub use options::{H264Profile, VideoRequest, option_lines, private_options, quantizer};

#[cfg(test)]
mod tests {
    use super::*;

    /// A 10 channel WAV (the conform can pass more than 8 channels): the ninth and tenth channel keep their own level.
    #[test]
    fn more_than_eight_audio_channels_are_encoded_without_overrunning_the_plane_table() {
        let dir = std::env::temp_dir().join(format!("sq-encode-10ch-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("ten.wav");
        let cfg = EncodeConfig {
            path: path.clone(),
            no_video: true,
            pcm_bits: 32,
            audio_rate: 48_000,
            audio_channels: 10,
            ..EncodeConfig::default()
        };
        let mut e = Encoder::open(&cfg).expect("a WAV encoder");
        let frames = 4800;
        let block: Vec<f32> = (0..frames * 10).map(|i| (i % 10) as f32 * 0.05).collect();
        e.audio(&block).expect("audio");
        e.finish().expect("finish");
        let mut reader = crate::shim::AudioReader::open(&path, 48_000, 10, None).expect("reader");
        let mut out = vec![0.0_f32; 1000 * 10];
        let n = reader.read(1000, &mut out).expect("read");
        assert!(n > 0);
        for c in [0, 8, 9] {
            assert!((out[c] - c as f32 * 0.05).abs() < 0.01, "channel {c}: {}", out[c]);
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// ProRes 422 and 4444 on the Mac: 10 frames through the VideoToolbox encoder (or `prores_ks` when it refuses); the file probes as ProRes.
    #[cfg(target_vendor = "apple")]
    #[test]
    fn mac_prores_422_and_4444_files_open_with_videotoolbox_and_probe_as_prores() {
        for prores in [3, 5] {
            mac_prores_file(prores);
        }
    }

    #[cfg(target_vendor = "apple")]
    fn mac_prores_file(prores: i32) {
        let dir = std::env::temp_dir().join(format!("sq-prores-vt-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("p.mov");
        let (w, h) = (128, 72);
        let cfg = EncodeConfig {
            path: path.clone(),
            hardware: true,
            width: w,
            height: h,
            fps_num: 25,
            fps_den: 1,
            prores,
            ..EncodeConfig::default()
        };
        let mut e = Encoder::open(&cfg).expect("a ProRes encoder");
        let name = e.video_name();
        println!("prores {prores} encoder opened: {name}");
        assert!(name == "prores_videotoolbox" || name == "prores_ks", "{name}");
        let frame: Vec<u8> = (0..w * h * 4).map(|i| (i % 251) as u8).collect();
        for i in 0..10 {
            e.video(&frame, PixelLayout::Bgra, w * 4, i).expect("frame");
        }
        e.finish().expect("finish");
        let info = crate::shim::Demux::open(&path).expect("probe").info();
        assert_eq!(info.codec, "prores");
        assert_eq!((info.width, info.height), (w, h));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn short_pixel_buffers_are_refused_before_the_shim_reads_them() {
        let dir = std::env::temp_dir().join(format!("sq-encode-unit-{}", std::process::id()));
        let cfg = EncodeConfig {
            path: dir.join("x.mp4"),
            width: 16,
            height: 16,
            fps_num: 30,
            fps_den: 1,
            ..EncodeConfig::default()
        };
        // Without FFmpeg `open` fails; with it the frame below is too short. Either way no read happens.
        if let Ok(mut e) = Encoder::open(&cfg) {
            assert!(e.video(&[0u8; 16 * 16], PixelLayout::Nv12, 16, 0).is_err());
            assert!(e.video(&[0u8; 16 * 16 * 3 / 2 - 1], PixelLayout::Nv12, 16, 0).is_err());
        }
        assert!(
            write_still(&dir.join("x.png"), StillCodec::Png, &[0u8; 8], PixelLayout::Rgba, 64, 16, 16, false, 0.9)
                .is_err()
        );
    }

    /// Display RGB (full range, as the program renders it) to Rec. 709 limited-range Y'CbCr, from the matrix.
    fn expected_ycbcr(rgb: [u8; 3]) -> [f64; 3] {
        let [r, g, b] = rgb.map(|v| f64::from(v) / 255.0);
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
        [16.0 + 219.0 * y, 128.0 + 224.0 * (b - y) / 1.8556, 128.0 + 224.0 * (r - y) / 1.5748]
    }

    /// RGBA patches (gray ramp and colors) through the real encoders (hardware first, then software) and back as raw
    /// yuv420p: every patch's Y, Cb and Cr lies within 1 code value of the Rec. 709 limited-range matrix. Guards the
    /// export against a luma offset, the wrong matrix or the wrong range in the RGB to YUV step.
    #[test]
    fn exported_patches_match_the_rec709_limited_range_matrix() {
        if !crate::shim::AVAILABLE {
            return;
        }
        let tool = std::env::var_os("SQ_FFMPEG")
            .map(|r| std::path::PathBuf::from(r).join("bin").join("ffmpeg"))
            .filter(|p| p.exists() || p.with_extension("exe").exists())
            .unwrap_or_else(|| "ffmpeg".into());
        if !std::process::Command::new(&tool).arg("-version").output().is_ok_and(|o| o.status.success()) {
            return;
        }
        let colors: [[u8; 3]; 16] = [
            [0, 0, 0],
            [16, 16, 16],
            [32, 32, 32],
            [64, 64, 64],
            [96, 96, 96],
            [128, 128, 128],
            [160, 160, 160],
            [192, 192, 192],
            [224, 224, 224],
            [255, 255, 255],
            [255, 0, 0],
            [0, 255, 0],
            [0, 0, 255],
            [255, 255, 0],
            [200, 120, 60],
            [60, 120, 200],
        ];
        let (w, h, cell) = (256usize, 128usize, 32usize);
        let mut rgba = vec![255u8; w * h * 4];
        for (i, c) in colors.iter().enumerate() {
            let (cx, cy) = ((i % 8) * cell, (i / 8) * cell);
            for y in cy..cy + cell {
                for x in cx..cx + cell {
                    rgba[(y * w + x) * 4..][..3].copy_from_slice(c);
                }
            }
        }
        let dir = std::env::temp_dir().join(format!("sq-encode-patches-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp folder");
        for hardware in [true, false] {
            let file = dir.join(format!("p-{hardware}.mp4"));
            let cfg = EncodeConfig {
                path: file.clone(),
                hardware,
                width: w as i32,
                height: h as i32,
                fps_num: 25,
                fps_den: 1,
                bitrate: 8_000_000,
                gop: 5,
                quality: 1.0,
                ..EncodeConfig::default()
            };
            let Ok(mut e) = Encoder::open(&cfg) else { continue };
            let name = e.video_name();
            for i in 0..5 {
                e.video(&rgba, PixelLayout::Rgba, (w * 4) as i32, i).expect("frame");
            }
            e.finish().expect("finish");
            let out = std::process::Command::new(&tool)
                .args(["-v", "error", "-i"])
                .arg(&file)
                .args(["-vf", "select=eq(n\\,3)", "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "yuv420p", "-"])
                .output()
                .expect("run ffmpeg");
            let yuv = out.stdout;
            assert_eq!(yuv.len(), w * h * 3 / 2, "{name}: decoded size");
            for (i, c) in colors.iter().enumerate() {
                let (cx, cy) = ((i % 8) * cell + cell / 2, (i / 8) * cell + cell / 2);
                let got = [
                    f64::from(yuv[cy * w + cx]),
                    f64::from(yuv[w * h + (cy / 2) * (w / 2) + cx / 2]),
                    f64::from(yuv[w * h + w * h / 4 + (cy / 2) * (w / 2) + cx / 2]),
                ];
                let want = expected_ycbcr(*c);
                eprintln!("{name} {c:?}: got {got:?} want {want:.1?}");
                for k in 0..3 {
                    assert!(
                        (got[k] - want[k]).abs() <= 1.5,
                        "{name} {c:?} plane {k}: got {} want {:.1}",
                        got[k],
                        want[k]
                    );
                }
            }
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
}
