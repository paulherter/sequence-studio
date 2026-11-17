use super::*;
use sq_audio_out::input::{MicError, MicSink};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};

/// Delivers one second of a sine the moment it starts.
struct Sine;

impl MicSource for Sine {
    fn sample_rate(&self) -> u32 {
        48_000
    }
    fn start(&mut self, mut sink: MicSink) -> Result<(), MicError> {
        for b in 0..100 {
            let block: Vec<f32> = (0..480).map(|i| 0.3 * ((b * 480 + i) as f32 * 0.05).sin()).collect();
            sink(&block);
        }
        Ok(())
    }
    fn stop(&mut self) {}
}

fn recorder(allowed: bool) -> (MicRecorder, Arc<AtomicU64>) {
    let ms = Arc::new(AtomicU64::new(0));
    let m = Arc::clone(&ms);
    let r = MicRecorder::with(
        Box::new(|| Box::new(Sine)),
        Box::new(move || allowed),
        Box::new(move || Duration::from_millis(m.load(Relaxed))),
    );
    (r, ms)
}

fn file(name: &str) -> PathBuf {
    std::env::temp_dir().join(format!("sq-mic-{}", std::process::id())).join(name)
}

#[test]
fn the_countdown_runs_three_two_one_then_records_and_stop_gives_the_take() {
    let (mut r, ms) = recorder(true);
    let url = file("take.wav");
    r.start(&url, Time::new(5, 1)).unwrap();
    assert_eq!((r.state(), r.countdown_left()), (VoiceRecorderState::Countdown, Some(3)));
    ms.store(1_100, Relaxed);
    assert_eq!(r.countdown_left(), Some(2));
    ms.store(2_500, Relaxed);
    assert_eq!(r.countdown_left(), Some(1));
    ms.store(3_000, Relaxed);
    assert_eq!((r.state(), r.countdown_left()), (VoiceRecorderState::Recording, None));
    let take = r.stop().unwrap();
    assert_eq!((take.anchor, take.duration), (Time::new(5, 1), Time::new(48_000, 48_000)));
    assert_eq!(r.state(), VoiceRecorderState::Idle);
    assert_eq!(std::fs::metadata(&url).unwrap().len(), 44 + 96_000);
}

#[test]
fn a_press_during_the_countdown_cancels_without_a_file() {
    let (mut r, _) = recorder(true);
    let url = file("canceled.wav");
    r.start(&url, Time::ZERO).unwrap();
    r.cancel();
    assert_eq!(r.state(), VoiceRecorderState::Idle);
    assert!(!url.exists());
}

#[test]
fn cancel_while_recording_drops_the_file() {
    let (mut r, ms) = recorder(true);
    let url = file("dropped.wav");
    r.start(&url, Time::ZERO).unwrap();
    ms.store(4_000, Relaxed);
    assert_eq!(r.state(), VoiceRecorderState::Recording);
    r.cancel();
    assert!(!url.exists() && r.state() == VoiceRecorderState::Idle);
}

#[test]
fn no_microphone_is_access_denied_and_a_second_start_is_refused() {
    let (mut r, _) = recorder(false);
    assert_eq!(r.start(&file("none.wav"), Time::ZERO), Err(VoiceRecorderError::AccessDenied));
    let (mut r, _) = recorder(true);
    r.start(&file("a.wav"), Time::ZERO).unwrap();
    assert!(matches!(r.start(&file("b.wav"), Time::ZERO), Err(VoiceRecorderError::Failed(_))));
    r.cancel();
}

#[test]
fn stopping_before_anything_was_recorded_fails() {
    let (mut r, _) = recorder(true);
    assert!(r.stop().is_err());
}

struct Broken;

impl MicSource for Broken {
    fn sample_rate(&self) -> u32 {
        48_000
    }
    fn start(&mut self, _sink: sq_audio_out::input::MicSink) -> Result<(), sq_audio_out::input::MicError> {
        Err(sq_audio_out::input::MicError::Failed("no device".into()))
    }
    fn stop(&mut self) {}
}

#[test]
fn a_microphone_that_fails_to_open_is_reported_once_then_the_recorder_is_free() {
    let ms = Arc::new(AtomicU64::new(0));
    let m = Arc::clone(&ms);
    let mut r = MicRecorder::with(
        Box::new(|| Box::new(Broken)),
        Box::new(|| true),
        Box::new(move || Duration::from_millis(m.load(Relaxed))),
    );
    r.start(&file("broken.wav"), Time::ZERO).unwrap();
    ms.store(3_000, Relaxed);
    assert_eq!(r.state(), VoiceRecorderState::Idle);
    assert_eq!(r.take_failure(), Some("no device".to_string()));
    assert_eq!(r.take_failure(), None);
    r.start(&file("again.wav"), Time::ZERO).unwrap();
    r.cancel();
}
