//! Loudness of a generated tone and the `.mogrt` host path (numbers, not looks).

use super::*;
use sq_core_model::{Clip, MediaFingerprint, SequenceFormat, Track, TrackKind};
use sq_core_time::{Id, Time};
use sq_draw_shell::ShellServices;
use sq_export::core::error::CancelToken;
use sq_export::encode::measure_output_audio;
use sq_media::waveform_data::WaveformData;
use std::path::PathBuf;

const RATE: u32 = 48_000;
const SECONDS: u32 = 4;

/// A mono 16-bit WAV with a 1 kHz sine at `amplitude` (full scale = 1.0).
fn tone_file(name: &str, amplitude: f64) -> PathBuf {
    let dir = crate::test_rig::unique_dir("sq-audio-services");
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join(name);
    let n = RATE * SECONDS;
    let mut data = Vec::with_capacity(n as usize * 2);
    for i in 0..n {
        let v = amplitude * (2.0 * std::f64::consts::PI * 1000.0 * f64::from(i) / f64::from(RATE)).sin();
        data.extend_from_slice(&((v * 32767.0).round() as i16).to_le_bytes());
    }
    let mut wav = Vec::new();
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + data.len() as u32).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    for v in [16u32, 0x0001_0001, RATE, RATE * 2, 0x0010_0002] {
        wav.extend_from_slice(&v.to_le_bytes());
    }
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&(data.len() as u32).to_le_bytes());
    wav.extend_from_slice(&data);
    std::fs::write(&path, wav).unwrap();
    path
}

/// The project media list and the one-track sequence the session seam hands over, for the tone at `path`.
fn setup(path: &std::path::Path) -> (Vec<MediaRef>, Timeline, TimeRange) {
    let mut media = MediaRef::new(Id::from_u128(1), "tone", &path.to_string_lossy(), MediaFingerprint::new(1));
    media.duration = Some(Time::seconds(i64::from(SECONDS)));
    let range = TimeRange::new(Time::ZERO, Time::seconds(i64::from(SECONDS)));
    let clip = Clip::new(Id::from_u128(2), "c", media.id, TrackKind::Audio, range, Time::ZERO);
    let mut ids = sq_core_time::SequentialIds::default();
    let mut track = Track::new(Id::from_u128(3), TrackKind::Audio);
    assert!(track.overwrite(clip, &mut ids).is_ok());
    let timeline = Timeline::new(Id::from_u128(4), "", SequenceFormat::new(Time::new(1, 30)), vec![track]);
    (vec![media], timeline, range)
}

#[test]
fn a_tone_measures_what_an_independent_decode_of_the_file_measures() {
    let (quiet, loud) = (tone_file("quiet.wav", 0.1), tone_file("loud.wav", 0.2));
    let measured = |p: &std::path::Path| {
        let (media, timeline, range) = setup(p);
        measure_lufs(&media, &[], &timeline, range, &CancelToken::new()).unwrap()
    };
    let (q, l) = (measured(&quiet), measured(&loud));
    // Twice the amplitude is 6.02 LU more.
    assert!((l - q - 6.02).abs() < 0.2, "quiet {q}, loud {l}");
    // The file's own decode (one channel) is the reference: a 1 kHz sine at -20 dBFS peak reads -23.0 LUFS, and the mix
    // plays the mono source on both channels, which sums to 3.01 LU more.
    let reference = measure_output_audio(&quiet).unwrap().unwrap().integrated_lufs;
    assert!((reference + 23.0).abs() < 0.1, "reference {reference}");
    assert!((q - (reference + 3.01)).abs() < 0.1, "mix {q}, file {reference}");
}

#[test]
fn a_silent_file_measures_as_none() {
    let silent = tone_file("silent.wav", 0.0);
    let (media, timeline, range) = setup(&silent);
    assert_eq!(measure_lufs(&media, &[], &timeline, range, &CancelToken::new()), None);
}

#[test]
fn a_missing_file_measures_as_none() {
    let (media, timeline, range) = setup(std::path::Path::new("/nonexistent/tone.wav"));
    assert_eq!(measure_lufs(&media, &[], &timeline, range, &CancelToken::new()), None);
}

#[test]
fn the_services_answer_loudness_and_waveforms_when_the_app_attached_them() {
    let mut services = super::super::analysis_services::AnalysisServices::new(Box::new(crate::PortableAnalysisBackend));
    assert!(!services.has_waveforms());
    let data = std::sync::Arc::new(WaveformData::new(48_000, 1, 10, 256, vec![vec![0.0, 1.0]]));
    let held = std::sync::Arc::clone(&data);
    services
        .attach_waveforms(std::rc::Rc::new(move |id| (id == Id::from_u128(7)).then(|| std::sync::Arc::clone(&held))));
    assert!(services.has_waveforms());
    assert!(services.waveform(Id::from_u128(7)).is_some());
    assert!(services.waveform(Id::from_u128(8)).is_none());
    let (media, timeline, range) = setup(&tone_file("t.wav", 0.1));
    let measure = services.loudness_measurer(media, Vec::new()).unwrap();
    assert!(measure(&timeline, range, &CancelToken::new()).is_some());
}

/// A file that is not a package: the host path reports the importer's own message, not "cannot be read in this build".
#[test]
fn a_file_that_is_not_a_template_is_refused_with_the_importers_message() {
    let dir = crate::test_rig::test_dir("sq-mogrt");
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("x.mogrt");
    std::fs::write(&path, b"not a zip").unwrap();
    let err = read_mogrt(&path).err().unwrap();
    assert!(err.contains("not a Motion Graphics Template"), "{err}");
    let mut services = super::super::analysis_services::AnalysisServices::new(Box::new(crate::PortableAnalysisBackend));
    assert_eq!(services.read_mogrt(&path).err().unwrap(), err);
    assert!(read_mogrt(std::path::Path::new("/nonexistent/x.mogrt")).is_err());
}

/// A clip that plays a nested sequence measures what the sequence holds, when the project's sequences are handed over.
#[test]
fn a_nested_sequence_is_measured_through_the_project_sequences() {
    let (media, inner, range) = setup(&tone_file("nested.wav", 0.1));
    let mut clip = Clip::new(Id::from_u128(20), "n", Id::from_u128(21), TrackKind::Audio, range, Time::ZERO);
    clip.sequence = Some(inner.id);
    let mut ids = sq_core_time::SequentialIds::default();
    let mut track = Track::new(Id::from_u128(22), TrackKind::Audio);
    assert!(track.overwrite(clip, &mut ids).is_ok());
    let outer = Timeline::new(Id::from_u128(23), "", SequenceFormat::new(Time::new(1, 30)), vec![track]);
    let direct = measure_lufs(&media, &[], &inner, range, &CancelToken::new()).unwrap();
    let nested = measure_lufs(&media, std::slice::from_ref(&inner), &outer, range, &CancelToken::new());
    assert!((nested.unwrap() - direct).abs() < 0.1, "nested {nested:?}, direct {direct}");
    assert_eq!(measure_lufs(&media, &[], &outer, range, &CancelToken::new()), None);
}
