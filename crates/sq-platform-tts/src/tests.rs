use super::*;
use std::time::{Duration, Instant};

fn voice(name: &str, language: &str) -> SpeechVoice {
    SpeechVoice { id: name.into(), name: name.into(), language: language.into(), enhanced: false }
}

fn out(name: &str) -> std::path::PathBuf {
    std::env::temp_dir().join(format!("sq-tts-{}-{name}", std::process::id()))
}

#[test]
fn own_language_first_then_language_and_name() {
    let mut list = vec![voice("Zoe", "en-US"), voice("Anna", "de-DE"), voice("Bob", "en-US"), voice("Alex", "en-GB")];
    sort_voices(&mut list, "de");
    let names: Vec<_> = list.iter().map(|v| v.name.as_str()).collect();
    assert_eq!(names, ["Anna", "Alex", "Bob", "Zoe"]);
}

#[test]
fn title_marks_enhanced() {
    let mut v = voice("Ava", "en-US");
    assert_eq!(v.title(), "Ava (en-US)");
    v.enhanced = true;
    assert_eq!(v.title(), "Ava (en-US) - enhanced");
}

#[test]
fn wav_round_trip_reports_rate_and_frames() {
    let p = out("rt.wav");
    let mut w = WavWriter::create(&p, 1, 22_050).unwrap_or_else(|_| unreachable!());
    assert!(w.write_f32(&[0.0, 0.5, -0.5, 2.0]).is_ok());
    assert_eq!(w.finish().ok(), Some(4));
    assert_eq!(wav_frames(&p).ok(), Some((22_050, 4)));
    let _ = std::fs::remove_file(p);
}

#[test]
fn render_cleans_text_and_returns_the_length() {
    let p = out("len.wav");
    let t = render(&ToneSpeech, "  hello   world  ", "tone", 0.5, &p);
    // "hello world" is 11 characters at 50 ms.
    assert_eq!(t, Ok(Time::new(11 * 2400, 48_000)));
    assert_eq!(wav_frames(&p).ok(), Some((48_000, 11 * 2400)));
    let _ = std::fs::remove_file(p);
}

#[test]
fn render_failures_leave_no_file() {
    let p = out("fail.wav");
    assert_eq!(render(&ToneSpeech, " \n ", "tone", 0.5, &p), Err(SpeechError::EmptyText));
    assert_eq!(render(&ToneSpeech, "hi", "none", 0.5, &p), Err(SpeechError::NoAudio));
    assert!(!p.exists());
    assert!(matches!(render(&ToneSpeech, "hi", "broken", 0.5, &p), Err(SpeechError::Failed(_))));
    assert!(!p.exists());
}

#[test]
fn job_runs_off_thread_and_wakes() {
    let p = out("job.wav");
    let woke = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let flag = Arc::clone(&woke);
    let wake: Arc<dyn Fn() + Send + Sync> = Arc::new(move || flag.store(true, std::sync::atomic::Ordering::SeqCst));
    let mut job = SpeechJob::spawn(Arc::new(ToneSpeech), "hello".into(), "tone".into(), 0.5, p.clone(), Some(wake));
    let end = Instant::now() + Duration::from_secs(10);
    while *job.poll() == JobState::Running && Instant::now() < end {
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(*job.poll(), JobState::Done(Time::new(5 * 2400, 48_000)));
    assert!(woke.load(std::sync::atomic::Ordering::SeqCst));
    let _ = std::fs::remove_file(p);
}

#[test]
fn job_reports_a_failure() {
    let mut job = SpeechJob::spawn(Arc::new(ToneSpeech), "hi".into(), "broken".into(), 0.5, out("jf.wav"), None);
    let end = Instant::now() + Duration::from_secs(10);
    while *job.poll() == JobState::Running && Instant::now() < end {
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(matches!(job.poll(), JobState::Failed(SpeechError::Failed(_))));
}
